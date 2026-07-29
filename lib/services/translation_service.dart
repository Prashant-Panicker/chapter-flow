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
  static const String model = 'kimi-k2.6';
  static const int _chunkChars = 1000;

  /// Verifies authentication without consuming completion tokens.
  Future<void> validateApiKey() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/models');
      final models = response.data?['data'];
      if (models is! List) {
        throw ApiKeyValidationException(
          'Moonshot returned an unexpected validation response.',
        );
      }
    } on ApiKeyValidationException {
      rethrow;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw ApiKeyValidationException(
          'Moonshot rejected this API key. Check the key and try again.',
        );
      }
      throw ApiKeyValidationException(
        'Could not verify the key with Moonshot. Check your connection and try again.',
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
      final addition = buffer.isEmpty ? p : '\n\n$p';
      if (buffer.isNotEmpty &&
          buffer.length + addition.length > _chunkChars) {
        flush();
        buffer.write(p);
      } else {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(p);
      }
      // Single huge paragraph: force flush so we still make progress.
      if (buffer.length > _chunkChars * 2) {
        flush();
      }
    }
    flush();
    return chunks.isEmpty ? [text] : chunks;
  }

  /// Translates [rawText] chunk by chunk.
  ///
  /// [onProgress] receives (current 1-based, total, partial joined text).
  /// [shouldCancel] is checked before each call and during the response stream.
  Future<String> translateChapter({
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
    int maxRetries = 2,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await _translateChunk(
          chunk,
          shouldCancel: shouldCancel,
          onStreamProgress: onStreamProgress,
        );
      } on TranslationCancelledException {
        rethrow;
      } on DioException catch (e) {
        lastError = e;
        final status = e.response?.statusCode;
        final retryable =
            status == 429 || status == 500 || status == 502 || status == 503;
        if (!retryable || attempt == maxRetries) {
          final msg = e.response?.data is Map
              ? (e.response?.data['error']?['message']?.toString() ??
                  e.message ??
                  'network error')
              : (e.message ?? 'network error');
          throw TranslationChunkFailure(index, total, msg);
        }
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      } catch (e) {
        lastError = e;
        if (attempt == maxRetries) {
          throw TranslationChunkFailure(index, total, e.toString());
        }
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    throw TranslationChunkFailure(
      index,
      total,
      lastError?.toString() ?? 'Unknown error',
    );
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
