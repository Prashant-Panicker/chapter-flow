import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/glossary_entry.dart';
import 'ai_provider.dart';
import 'translation_exceptions.dart';
import 'translation_prompts.dart';

/// Low-level chunking and streaming helpers used by [TranslationService].
class TranslationEngine {
  TranslationEngine({
    required this.dio,
    required this.model,
    required this.mode,
    required this.provider,
    required this.cancelToken,
    required this.modelParams,
  });

  final Dio dio;
  final String model;
  final TranslationMode mode;
  final AiProvider provider;
  final CancelToken cancelToken;
  final Map<String, dynamic> Function({
    required bool thinkingEnabled,
    bool stream,
    int? maxTokens,
  }) modelParams;

  static const int chunkChars = 3000;
  static const int maxInjectedTerms = 60;
  static const int continuityChars = 400;

  List<String> chunkText(String text) => _chunk(text);

  List<String> _chunk(String text) {
    final paragraphs =
        text.split(RegExp(r'\n+')).where((p) => p.trim().isNotEmpty).toList();
    if (paragraphs.isEmpty) {
      return text.trim().isEmpty ? <String>[] : [text.trim()];
    }

    final chunks = <String>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isNotEmpty) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
    }

    for (final p in paragraphs) {
      if (p.length > chunkChars) {
        flush();
        var start = 0;
        while (p.length - start > chunkChars) {
          var end = start + chunkChars;
          if (_isLowSurrogate(p.codeUnitAt(end))) end--;
          final part = p.substring(start, end).trim();
          if (part.isNotEmpty) chunks.add(part);
          start = end;
        }
        if (start < p.length) buffer.write(p.substring(start));
        continue;
      }
      final addition = buffer.isEmpty ? p : '\n\n$p';
      if (buffer.isNotEmpty &&
          buffer.length + addition.length > chunkChars) {
        flush();
        buffer.write(p);
      } else {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(p);
      }
    }
    flush();
    return chunks.isEmpty ? [text] : chunks;
  }

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  List<GlossaryEntry> relevantTerms(
    String chunk,
    List<GlossaryEntry> glossary,
  ) {
    if (glossary.isEmpty) return const [];
    final matches =
        glossary.where((e) => chunk.contains(e.source)).toList(growable: false);
    if (matches.length <= maxInjectedTerms) return matches;
    final sorted = matches.toList()
      ..sort((a, b) => b.source.length.compareTo(a.source.length));
    return sorted.take(maxInjectedTerms).toList(growable: false);
  }

  String _glossaryBlock(List<GlossaryEntry> terms) {
    if (terms.isEmpty) return '';
    final names =
        terms.where((e) => e.style == GlossaryStyle.pinyin).toList();
    final concepts =
        terms.where((e) => e.style == GlossaryStyle.english).toList();

    String describe(GlossaryEntry e) => e.type.isEmpty
        ? '${e.source} = ${e.english}'
        : '${e.source} = ${e.english}  (${e.type})';

    final buffer = StringBuffer(
      'GLOSSARY for this novel. These renderings are already established — '
      'reuse them exactly, do not invent alternatives.\n',
    );
    if (names.isNotEmpty) {
      buffer.writeln('\nWrite these as shown (Pinyin names, never translated):');
      for (final e in names) {
        buffer.writeln('- ${describe(e)}');
      }
    }
    if (concepts.isNotEmpty) {
      buffer.writeln('\nUse these exact English terms:');
      for (final e in concepts) {
        buffer.writeln('- ${describe(e)}');
      }
    }
    if (names.isNotEmpty && concepts.isNotEmpty) {
      buffer.writeln(
        '\nIf the same term appears in both lists, choose by context: the '
        'Pinyin form names a specific individual, the English form names a '
        'kind of thing.',
      );
    }
    return buffer.toString();
  }

  String tailOf(String text, int maxChars) {
    if (text.isEmpty) return '';
    final tail =
        text.length <= maxChars ? text : text.substring(text.length - maxChars);
    final breakAt = tail.indexOf('\n\n');
    if (breakAt >= 0 && breakAt < tail.length - 40) {
      return tail.substring(breakAt + 2).trim();
    }
    return tail.trim();
  }

  Future<String> translateChunkWithRetry(
    String chunk, {
    required int index,
    required int total,
    required List<GlossaryEntry> terms,
    required String continuity,
    required bool Function() shouldCancel,
    required void Function(String partialChunk) onStreamProgress,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= 4; attempt++) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      try {
        return await translateChunk(
          chunk,
          terms: terms,
          continuity: continuity,
          shouldCancel: shouldCancel,
          onStreamProgress: onStreamProgress,
        );
      } on TranslationCancelledException {
        rethrow;
      } on DioException catch (e) {
        if (shouldCancel()) {
          throw TranslationCancelledException();
        }
        lastError = e;
        final status = e.response?.statusCode;
        final retryable =
            status == 429 || status == 500 || status == 502 || status == 503;
        final retryLimit = status == 429 ? 4 : 2;
        if (!retryable || attempt >= retryLimit) {
          final msg = status == 429
              ? 'Rate limit reached. Try again shortly.'
              : await _describeApiError(e);
          throw TranslationChunkFailure(index, total, msg);
        }
        await _waitBeforeRetry(_retryDelay(e, attempt), shouldCancel);
      } catch (e) {
        if (shouldCancel()) {
          throw TranslationCancelledException();
        }
        lastError = e;
        if (attempt >= 2) {
          throw TranslationChunkFailure(index, total, e.toString());
        }
        await _waitBeforeRetry(
          Duration(seconds: 2 * (attempt + 1)),
          shouldCancel,
        );
      }
    }
    throw TranslationChunkFailure(
      index,
      total,
      lastError?.toString() ?? 'Unknown error',
    );
  }

  Future<String> _describeApiError(DioException e) async {
    final data = e.response?.data;
    String? body;

    if (data is Map) {
      final message = data['error']?['message'] ?? data['message'];
      if (message != null) return message.toString();
    } else if (data is String) {
      body = data;
    } else if (data is ResponseBody) {
      try {
        final bytes = <int>[];
        await for (final part in data.stream) {
          bytes.addAll(part);
          if (bytes.length > 8192) break;
        }
        body = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        body = null;
      }
    }

    if (body != null && body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final message = decoded['error']?['message'] ?? decoded['message'];
          if (message != null) return message.toString();
        }
      } catch (_) {}
      final trimmed = body.trim();
      return trimmed.length > 300 ? trimmed.substring(0, 300) : trimmed;
    }

    final status = e.response?.statusCode;
    if (status != null) return 'Server rejected the request (HTTP $status).';
    return e.message ?? 'network error';
  }

  Future<void> _waitBeforeRetry(
    Duration delay,
    bool Function() shouldCancel,
  ) async {
    await Future.any<void>([
      Future<void>.delayed(delay),
      cancelToken.whenCancel.then<void>((_) {}),
    ]);
    if (shouldCancel() || cancelToken.isCancelled) {
      throw TranslationCancelledException();
    }
  }

  Duration _retryDelay(DioException error, int attempt) {
    final headers = error.response?.headers;
    final retryAfter = headers?.value('retry-after');
    final retryAfterDelay = _parseRetryAfter(retryAfter);
    if (retryAfterDelay != null) return retryAfterDelay;

    for (final name in const [
      'x-ratelimit-reset-tokens',
      'x-ratelimit-reset-requests',
    ]) {
      final resetDelay = _parseDuration(headers?.value(name));
      if (resetDelay != null) return resetDelay;
    }

    if (error.response?.statusCode == 429) {
      return Duration(seconds: attempt == 0 ? 30 : 60);
    }
    return Duration(seconds: 2 * (attempt + 1));
  }

  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds.clamp(1, 300));

    final date = DateTime.tryParse(value);
    if (date == null) return null;
    final delay = date.toUtc().difference(DateTime.now().toUtc());
    return Duration(
      milliseconds: delay.inMilliseconds.clamp(1000, 300000),
    );
  }

  Duration? _parseDuration(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final match = RegExp(
      r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+(?:\.\d+)?)s)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(3) ?? '') ?? 0;
    final milliseconds =
        ((hours * 3600 + minutes * 60 + seconds) * 1000).ceil();
    if (milliseconds <= 0) return null;
    return Duration(milliseconds: milliseconds.clamp(1000, 300000));
  }

  Future<String> translateChunk(
    String chunk, {
    required List<GlossaryEntry> terms,
    required String continuity,
    required bool Function() shouldCancel,
    required void Function(String partialChunk) onStreamProgress,
  }) async {
    final prompt = StringBuffer();
    final glossary = _glossaryBlock(terms);
    if (glossary.isNotEmpty) {
      prompt
        ..write(glossary)
        ..write('\n');
    }
    if (continuity.isNotEmpty) {
      prompt
        ..writeln(
          'END OF THE PREVIOUS PASSAGE, already translated. It is context '
          'for tone and pronouns only — do not repeat or re-translate it:',
        )
        ..writeln(continuity)
        ..writeln();
    }
    final isGist = mode == TranslationMode.gist;
    prompt
      ..writeln(
        isGist
            ? 'Produce a condensed English version of the following novel '
                'text. Keep event order, meaningful dialogue, and context; '
                'cut pure filler. Keep paragraph breaks where scenes or '
                'speakers change.'
            : 'Translate the following novel text into English. Keep paragraph '
                'breaks.',
      )
      ..writeln()
      ..write(chunk);

    final response = await dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: cancelToken,
      data: {
        ...modelParams(thinkingEnabled: false, stream: true),
        'messages': [
          {
            'role': 'system',
            'content': isGist ? kGistSystemPrompt : kSystemPrompt,
          },
          {'role': 'user', 'content': prompt.toString()},
        ],
      },
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Accept': 'text/event-stream',
        },
      ),
    );

    final buffer = StringBuffer();
    final stream = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in stream) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      if (line.isEmpty) continue;
      if (!line.startsWith('data: ')) continue;

      final data = line.substring(6).trim();
      if (data == '[DONE]') break;

      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final delta = json['choices']?[0]?['delta'];
        final content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) {
          buffer.write(content);
          onStreamProgress(buffer.toString());
        }
      } catch (_) {}
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      throw StateError('Empty response from ${provider.displayName} API');
    }
    return result;
  }
}
