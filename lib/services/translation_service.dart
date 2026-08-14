import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/glossary_entry.dart';

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
    'You are an expert translator of Chinese web novels (Wuxia, Xianxia, '
    'Xuanhuan, and modern web fiction). Translate the provided text into '
    'natural, high-quality English.\n'
    '\n'
    'NAMING RULES — follow these exactly, they matter more than style:\n'
    '1. Personal names of characters, and proper names of places, sects, '
    'clans and organisations, are written in Pinyin (no tone marks, '
    'capitalised). Never translate them literally.\n'
    '2. EVERYTHING else is written in natural English: species and races, '
    'cultivation realms, techniques, artifacts, pills, formations, '
    'bloodlines, titles and ranks.\n'
    '3. A word that names a kind of thing is English even when it looks like '
    'a name. 朱雀 as a creature is "Vermillion Bird", not "Zhuque". Use Pinyin '
    'only when the word is the name of one specific individual, place or '
    'organisation. So "青云是朱雀" is "Qingyun is a Vermillion Bird".\n'
    '4. Once a term has an English form, never vary it. Reuse the exact same '
    'wording every time it appears.\n'
    '5. Before writing each paragraph, silently classify every proper-'
    'looking term you meet: is it the name of one particular individual — a '
    'person, or one specific named creature — or is it a category word: a '
    'sect, clan, pill, technique, artifact, formation, bloodline, title, '
    'rank, or a species/type of thing? Only the former is Pinyin. When '
    'unsure, default to English — over-Pinyinizing is the more common '
    'mistake.\n'
    '\n'
    'Translate paragraph-by-paragraph without summarising. Preserve '
    'paragraph breaks. Do not add commentary, notes or headings. Output only '
    'the translated text.';

const String _glossarySystemPrompt =
    'You build a translation glossary from Chinese web-novel text.\n'
    'Return ONLY a JSON array, no markdown fence and no commentary. Each '
    'element must be:\n'
    '{"source":"<exact substring from the text>","english":"<rendering>",'
    '"style":"pinyin"|"english","type":"<short description>"}\n'
    '\n'
    'style is "pinyin" ONLY for personal names of characters and proper '
    'names of places, sects, clans and organisations; english must then be '
    'the Pinyin, no tone marks, capitalised.\n'
    'style is "english" for everything else: species, races, cultivation '
    'realms, techniques, artifacts, pills, formations, bloodlines, titles '
    'and ranks. A word naming a kind of thing is "english" even when it '
    'looks like a name (朱雀 -> Vermillion Bird, style "english"). Use '
    '"pinyin" only for one specific individual, place or organisation.\n'
    'type is a short free-form description in your own words, such as '
    '"protagonist", "spirit beast species", "sword sect" or "cultivation '
    'realm".\n'
    'Before assigning style, silently check: is this the name of one '
    'particular individual (a person, or one specific named creature), or a '
    'category — a sect, pill, technique, artifact, formation, bloodline, '
    'title, rank, or species/type? Only the former is "pinyin". When '
    'unsure, default to "english".\n'
    'Include only recurring or plot-relevant terms. At most 40 entries.';

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
  static final Map<String, String> _titleCache = <String, String>{};
  static const String model = 'kimi-k2.6';

  /// The English output has to fit the server's default output limit, so
  /// this stays at the size that is known to complete reliably. The glossary
  /// is what keeps naming consistent across the extra seams.
  static const int _chunkChars = 3000;

  /// Upper bound on how much of a chapter is sent for glossary extraction.
  static const int _glossarySampleChars = 12000;

  /// Caps how many bindings are injected into a single chunk prompt.
  static const int _maxInjectedTerms = 60;

  /// How much of the previous chunk's English is carried forward for tone
  /// and pronoun continuity.
  static const int _continuityChars = 400;

  void cancel() {
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('Translation stopped');
    }
  }

  /// Translates a novel name or chapter heading into English. Short,
  /// single-shot request that stays out of the chapter queue so it never
  /// blocks chapter translation. Returns an empty string on failure.
  Future<String> translateTitle(String title) async {
    final source = title.trim();
    if (source.isEmpty) return '';
    if (!RegExp(r'[^\x00-\x7F]').hasMatch(source)) return source;

    final cached = _titleCache[source];
    if (cached != null) return cached;

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/chat/completions',
        data: {
          'model': model,
          // Thinking is off here, so temperature must stay 0.6 — pairing
          // disabled thinking with any other value gets a 400. (1.0 is
          // required instead when thinking is enabled, as in the chunk
          // and glossary calls.)
          'temperature': 0.6,
          'thinking': {'type': 'disabled'},
          'messages': [
            {
              'role': 'system',
              'content':
                  'You translate Chinese web novel names and chapter headings '
                  'into English. Personal names of characters and proper '
                  'names of places, sects and organisations stay in Pinyin. '
                  'Everything else becomes natural English — species, realms, '
                  'techniques, artifacts, titles. A word naming a kind of '
                  'thing is English even when it looks like a name '
                  '(朱雀 -> Vermillion Bird). Render chapter markers as '
                  '"Chapter N". Reply with only the English title on a single '
                  'line — no quotes, no explanation.',
            },
            {'role': 'user', 'content': source},
          ],
        },
      );
      final content =
          response.data?['choices']?[0]?['message']?['content'] as String?;
      final english = content
              ?.split('\n')
              .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
              .trim()
              .replaceAll(RegExp(r'^["“”\u0027]+|["“”\u0027]+$'), '')
              .trim() ??
          '';
      if (english.isEmpty || english.length > 120) return '';
      if (_titleCache.length > 300) _titleCache.clear();
      _titleCache[source] = english;
      return english;
    } catch (_) {
      return '';
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

  /// Extracts term bindings from a chapter's source text.
  ///
  /// Deliberately kept out of [_translationQueue] and off the critical path:
  /// callers run it alongside the first chunk so it adds no perceived delay,
  /// and every failure mode returns an empty list rather than throwing.
  Future<List<GlossaryEntry>> extractGlossary({
    required String rawText,
    required List<GlossaryEntry> known,
    required bool Function() shouldCancel,
  }) async {
    final sample = rawText.length > _glossarySampleChars
        ? rawText.substring(0, _glossarySampleChars)
        : rawText;
    if (sample.trim().length < 200) return const [];
    if (shouldCancel()) return const [];

    // Only mention terms that actually occur here, so the prompt stays small
    // however long the novel gets.
    final relevant = known
        .where((e) => sample.contains(e.source))
        .take(80)
        .map((e) => e.source)
        .toSet();
    final knownBlock = relevant.isEmpty
        ? ''
        : 'Already established, do not repeat these: '
            '${relevant.join('、')}\n\n';

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/chat/completions',
        cancelToken: _cancelToken,
        data: {
          'model': model,
          // kimi-k2.6 ties temperature to thinking mode: 0.6 when disabled,
          // 1.0 when enabled — mismatching the two gets a 400.
          'temperature': 1.0,
          'thinking': {'type': 'enabled'},
          // Reasoning tokens share this budget with the JSON output, so
          // keep it generous even though the glossary itself is short.
          'max_tokens': 16000,
          'messages': [
            {'role': 'system', 'content': _glossarySystemPrompt},
            {'role': 'user', 'content': '$knownBlock$sample'},
          ],
        },
      );
      if (shouldCancel()) return const [];
      final content =
          response.data?['choices']?[0]?['message']?['content'] as String?;
      return _parseGlossary(content);
    } catch (_) {
      return const [];
    }
  }

  List<GlossaryEntry> _parseGlossary(String? content) {
    if (content == null || content.isEmpty) return const [];
    final start = content.indexOf('[');
    final end = content.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    try {
      final decoded = jsonDecode(content.substring(start, end + 1));
      if (decoded is! List) return const [];
      final entries = <GlossaryEntry>[];
      for (final row in decoded) {
        final entry = GlossaryEntry.tryParse(row);
        if (entry != null) entries.add(entry);
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// Picks the bindings worth spending prompt space on for this chunk.
  /// Longer terms first: they are the most specific and the most likely to be
  /// mistranslated if left unpinned.
  List<GlossaryEntry> _relevantTerms(
    String chunk,
    List<GlossaryEntry> glossary,
  ) {
    if (glossary.isEmpty) return const [];
    final matches =
        glossary.where((e) => chunk.contains(e.source)).toList(growable: false);
    if (matches.length <= _maxInjectedTerms) return matches;
    final sorted = matches.toList()
      ..sort((a, b) => b.source.length.compareTo(a.source.length));
    return sorted.take(_maxInjectedTerms).toList(growable: false);
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
  /// [glossary] is read fresh before every chunk, so bindings discovered while
  /// the chapter is still translating apply to the chunks that follow.
  Future<String> translateChapter({
    required String rawText,
    required void Function(int current, int total, String partialText)
        onProgress,
    required bool Function() shouldCancel,
    List<GlossaryEntry> Function()? glossary,
  }) {
    return _enqueueTranslation(
      () => _translateChapter(
        rawText: rawText,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
        glossary: glossary,
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
    List<GlossaryEntry> Function()? glossary,
  }) async {
    final chunks = _chunk(rawText);
    if (chunks.isEmpty) return '';

    final total = chunks.length;
    final translatedParts = <String>[];

    for (var i = 0; i < total; i++) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      final terms = _relevantTerms(chunks[i], glossary?.call() ?? const []);
      final continuity = translatedParts.isEmpty
          ? ''
          : _tailOf(translatedParts.last, _continuityChars);
      final translated = await _translateChunkWithRetry(
        chunks[i],
        index: i,
        total: total,
        terms: terms,
        continuity: continuity,
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

  /// Trailing slice of already-translated English, cut at a paragraph or
  /// sentence boundary so the model is not handed a fragment.
  String _tailOf(String text, int maxChars) {
    if (text.isEmpty) return '';
    final tail =
        text.length <= maxChars ? text : text.substring(text.length - maxChars);
    final breakAt = tail.indexOf('\n\n');
    if (breakAt >= 0 && breakAt < tail.length - 40) {
      return tail.substring(breakAt + 2).trim();
    }
    return tail.trim();
  }

  Future<String> _translateChunkWithRetry(
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
        return await _translateChunk(
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

  /// Pulls the API's own error text out of a failed request.
  ///
  /// Chunk requests are streamed, so Dio hands back an undecoded
  /// [ResponseBody] rather than a parsed map — without draining it here the
  /// user only ever sees Dio's generic "status code 400" boilerplate, which
  /// says nothing about which field the server rejected.
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
      } catch (_) {
        // Not JSON — fall through and show the raw body.
      }
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
  ) async {    await Future.any<void>([
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
    prompt
      ..writeln(
        'Translate the following novel text into English. Keep paragraph '
        'breaks.',
      )
      ..writeln()
      ..write(chunk);

    final response = await _dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: _cancelToken,
      data: {
        'model': model,
        // kimi-k2.6 ties temperature to thinking mode: 0.6 when disabled,
        // 1.0 when enabled — mismatching the two gets a 400.
        'temperature': 1.0,
        'stream': true,
        'thinking': {'type': 'enabled'},
        // Reasoning tokens and the translated chunk share this cap, so it
        // needs real headroom on top of a ~3000-char source chunk.
        'max_tokens': 32768,
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
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
        // Thinking is on, so early deltas carry reasoning_content instead
        // of content — reading only `content` already filters those out,
        // which is what we want: reasoning text must never reach the page.
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
