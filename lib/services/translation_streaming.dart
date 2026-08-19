part of 'translation_service.dart';

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

    final response = await _dio.post<ResponseBody>(
      '/chat/completions',
      cancelToken: _cancelToken,
      data: {
        // Thinking stays disabled for the live stream so tokens appear
        // immediately. DeepSeek uses a plain non-thinking call.
        ..._modelParams(thinkingEnabled: false, stream: true),
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
      } catch (_) {
        // Ignore keep-alive or malformed lines
      }
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) {
      throw StateError('Empty response from ${provider.displayName} API');
    }
    return result;
  }
}
