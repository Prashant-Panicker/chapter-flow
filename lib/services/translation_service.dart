import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/glossary_entry.dart';
import 'ai_provider.dart';
import 'translation_exceptions.dart';
import 'translation_prompts.dart';

export 'translation_exceptions.dart';

part 'translation_streaming.dart';
part 'translation_core.dart';

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
          // Streaming keeps the connection alive with continuous data,
          // so a longer receiveTimeout is safe as a backstop.
          receiveTimeout: const Duration(minutes: 10),
        ));

  final TranslationMode mode;
  final AiProvider provider;
  final String model;
  final Dio _dio;
  final CancelToken _cancelToken = CancelToken();
  static Future<void> _translationQueue = Future<void>.value();
  static final Map<String, String> _titleCache = <String, String>{};

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

  /// Builds the common model / temperature / thinking fields for a request.
  /// Both Kimi and DeepSeek accept a `thinking` object. Kimi additionally
  /// requires temperature 0.6 when thinking is off and 1.0 when on.
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
      // kimi-k2.6: 0.6 when thinking disabled, 1.0 when enabled.
      map['temperature'] = thinkingEnabled ? 1.0 : 0.6;
    } else {
      // DeepSeek: lower temp for stable translation; thinking off for speed.
      map['temperature'] = thinkingEnabled ? 1.0 : 0.3;
    }
    return map;
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
          // Glossary benefits from thinking on Kimi; DeepSeek uses plain call.
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
}
