import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/glossary_entry.dart';
import 'ai_provider.dart';
import 'translation_engine.dart';
import 'translation_exceptions.dart';
import 'translation_prompts.dart';

export 'translation_exceptions.dart';

class TranslationService {
  TranslationService({
    required String apiKey,
    this.mode = TranslationMode.full,
    this.provider = AiProvider.kimi,
  })  : model = provider.modelId,
        _dio = Dio(BaseOptions(
          baseUrl: provider.baseUrl,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(minutes: 10),
        )) {
    _engine = TranslationEngine(
      dio: _dio,
      model: model,
      mode: mode,
      provider: provider,
      cancelToken: _cancelToken,
      modelParams: _modelParams,
    );
  }

  final TranslationMode mode;
  final AiProvider provider;
  final String model;
  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  late final TranslationEngine _engine;
  static Future<void> _translationQueue = Future<void>.value();
  static final Map<String, String> _titleCache = <String, String>{};

  static const int _glossarySampleChars = 12000;

  void cancel() {
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('Translation stopped');
    }
  }

  Map<String, dynamic> _modelParams({
    required bool thinkingEnabled,
    bool stream = false,
    int? maxTokens,
  }) {
    final map = <String, dynamic>{
      'model': model,
      if (stream) 'stream': true,
      if (maxTokens != null) 'max_tokens': maxTokens,
      'thinking': {'type': thinkingEnabled ? 'enabled' : 'disabled'},
    };
    if (provider.tiesTemperatureToThinking) {
      map['temperature'] = thinkingEnabled ? 1.0 : 0.6;
    } else {
      map['temperature'] = thinkingEnabled ? 1.0 : 0.3;
    }
    return map;
  }

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
          ..._modelParams(thinkingEnabled: false),
          'messages': [
            {
              'role': 'system',
              'content':
                  'You translate Chinese web novel names and chapter headings '
                  'into English. Personal names of characters stay in Pinyin. '
                  'Everything else becomes natural English — sects, places, '
                  'species, realms, techniques, divine abilities, artifacts, '
                  'titles. A word naming a kind of thing is English even when '
                  'it looks like a name (朱雀 -> Vermillion Bird). Render '
                  'chapter markers as "Chapter N". Reply with only the English '
                  'title on a single line — no quotes, no explanation.',
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

  Future<void> validateApiKey() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/models');
      final models = response.data?['data'];
      if (models is! List) {
        throw ApiKeyValidationException('Could not verify key.');
      }
    } on ApiKeyValidationException {
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw ApiKeyValidationException('Invalid API key.');
      }
      throw ApiKeyValidationException(
        'Could not verify key. Check your connection.',
      );
    }
  }

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
          ..._modelParams(thinkingEnabled: true, maxTokens: 16000),
          'messages': [
            {'role': 'system', 'content': kGlossarySystemPrompt},
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

  List<String> chunkText(String text) => _engine.chunkText(text);

  Future<String> translateChapter({
    required String rawText,
    required void Function(int current, int total, String partialText)
        onProgress,
    required bool Function() shouldCancel,
    List<GlossaryEntry> Function()? glossary,
    int startFromChunk = 0,
    List<String> priorParts = const [],
    void Function(int completedChunks, int total, String partialText)?
        onChunkComplete,
  }) {
    return _enqueueTranslation(
      () => _translateChapter(
        rawText: rawText,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
        glossary: glossary,
        startFromChunk: startFromChunk,
        priorParts: priorParts,
        onChunkComplete: onChunkComplete,
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
    int startFromChunk = 0,
    List<String> priorParts = const [],
    void Function(int completedChunks, int total, String partialText)?
        onChunkComplete,
  }) async {
    final chunks = _engine.chunkText(rawText);
    if (chunks.isEmpty) return '';

    final total = chunks.length;
    final safeStart = startFromChunk.clamp(0, total);
    final translatedParts = <String>[
      ...priorParts.take(safeStart),
    ];

    if (translatedParts.isNotEmpty) {
      onProgress(safeStart, total, translatedParts.join('\n\n'));
    }

    for (var i = safeStart; i < total; i++) {
      if (shouldCancel()) {
        throw TranslationCancelledException();
      }
      final terms =
          _engine.relevantTerms(chunks[i], glossary?.call() ?? const []);
      final continuity = translatedParts.isEmpty
          ? ''
          : _engine.tailOf(translatedParts.last, TranslationEngine.continuityChars);
      final translated = await _engine.translateChunkWithRetry(
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
      final joined = translatedParts.join('\n\n');
      onProgress(i + 1, total, joined);
      onChunkComplete?.call(i + 1, total, joined);
    }

    return translatedParts.join('\n\n');
  }
}
