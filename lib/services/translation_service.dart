import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

class TranslationCancelledException implements Exception {
  @override
  String toString() => 'Translation cancelled by user';
}

class TranslationChunkFailure implements Exception {
  final int chunkIndex; // 0-based
  final int chunkTotal;
  final String message;
  TranslationChunkFailure(this.chunkIndex, this.chunkTotal, this.message);
  @override
  String toString() =>
      'Chunk ${chunkIndex + 1}/$chunkTotal failed: $message';
}

class MissingApiKeyException implements Exception {
  @override
  String toString() =>
      'No Moonshot API key found. Add your key in Settings.';
}

class ApiKeyValidationException implements Exception {
  ApiKeyValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

const String _systemPrompt =
    'You are an expert translator specializing in Chinese web novels '
    '(Wuxia, Xianxia, Xuanhuan, and modern web fiction). Translate the '
    'provided text into natural, high-quality English. Keep proper names '
    'in Pinyin (do not translate them literally). Ensure cultivation '
    'realms, techniques, and idioms fit progression-fantasy lore. '
    'Translate paragraph-by-paragraph without summarization. Preserve '
    'paragraph breaks. Do not add commentary or notes. Output only the '
    'translated text.';

class TranslationService {
  TranslationService({required String apiKey})
      : _dio = Dio(BaseOptions(
          baseUrl: 'https://api.moonshot.ai/v1',
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 30),
          // Streaming keeps the connection alive with continuous data,
          // so a longer receiveTimeout is safe as a backstop.
          receiveTimeout: const Duration(minutes: 10),
        ));

  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  static Future<void> _translationQueue = Future<void>.value();
  static const String model = 'kimi-k2.6';
  static const int _chunkChars = 3000;

  void cancel() {
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('Translation stopped');
    }
  }

  /// Verifies authentication without consuming completion tokens.
  Future<void> validateApiKey() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/models');
      final models = response.data?['data'];
      if (models is! List) {
        throw ApiKeyValidationException(
          'Could not verify key.',
        );
      }
    } on ApiKeyValidationException {
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw ApiKeyValidationException(
          'Invalid API key.',
        );
      }
      throw ApiKeyValidationException(
        'Could not verify key. Check your connection.',
      );
    }
  }

  /// Splits raw source text into paragraph-respecting chunks.
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
      if (p.length > _chunkChars) {
        flush();
        var start = 0;
        while (p.length - start > _chunkChars) {
          var end = start + _chunkChars;
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
          buffer.length + addition.length > _chunkChars) {
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

  /// Translates [rawText] chunk by chunk.
  ///
  /// [onProgress] receives (current 1-based, total, partial joined text).
  /// [shouldCancel] is checked before each call and during the response stream.
  Future<String> translateChapter({
    required String rawText,
    required void Function(int current, int total, String partialText)
        onProgress,
    required bool Function() shouldCancel,
  }) {
    return _enqueueTranslation(
      () => _translateChapter(
        rawText: rawText,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      ),
    );
  }

  Future<T> _enqueueTranslation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _translationQueue = _translationQueue.then((_) async {
      try {
        if (_cancelToken.isCancelled) {
          throw TranslationCancelledException();
        }
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<String> _translateChapter({
    required String rawText,
    required void Function(int current, int total, String partialText)
        onProgress,
    required bool Function() shouldCancel,
  }) async {
    final chunks = _chunk(rawText);
    if (chunks.isEmpty) return '';

    final total = chunks.length;
    final translatedParts = <String>[];

    for (var i = 0; i < total; i++) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      final translated = await _translateChunkWithRetry(
        chunks[i],
        index: i,
        total: total,
        shouldCancel: shouldCancel,
        onStreamProgress: (partialChunk) {
          onProgress(
            i + 1,
            total,
            [...translatedParts, partialChunk].join('\n\n'),
          );
        },
      );
      translatedParts.add(translated);
      onProgress(i + 1, total, translatedParts.join('\n\n'));
    }

    return translatedParts.join('\n\n');
  }

  Future<String> _translateChunkWithRetry(
    String chunk, {
    required int index,
    required int total,
    required bool Function() shouldCancel,
    required void Function(String partialChunk) onStreamProgress,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= 4; attempt++) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      try {
        return await _translateChunk(
          chunk,
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
              : e.response?.data is Map
                  ? (e.response?.data['error']?['message']?.toString() ??
                      e.message ??
                      'network error')
                  : (e.message ?? 'network error');
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

  Future<void> _waitBeforeRetry(
    Duration delay,
    bool Function() shouldCancel,
  ) async {
    await Future.any<void>([
      Future<void>.delayed(delay),
      _cancelToken.whenCancel.then<void>((_) {}),
    ]);
    if (shouldCancel() || _cancelToken.isCancelled) {
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

  /// Streaming version – tokens arrive continuously so the receiveTimeout
  /// is continuously refreshed and the old 3-minute abort no longer occurs.
  Future<String> _translateChunk(
    String chunk, {
    required bool Function() shouldCancel,
    required void Function(String partialChunk) onStreamProgress,
  }) async {
    final response = await _dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: _cancelToken,
      data: {
        'model': model,
        // International Kimi models require temperature == 1.
        'temperature': 0.6,                // Instant mode uses 0.6
        'stream': true,
        'thinking': {'type': 'disabled'},  // ← this is Instant mode
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {
            'role': 'user',
            'content':
                'Translate the following novel text into English. '
                'Keep paragraph breaks.\n\n$chunk',
          },
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
      } catch (_) {
        // Ignore keep-alive or malformed lines
      }
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      throw StateError('Empty response from Moonshot API');
    }
    return result;
  }
}
