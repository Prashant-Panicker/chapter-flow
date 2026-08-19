part of 'translation_service.dart';

  /// Splits raw source text into paragraph-respecting chunks.
  ///
  /// Public so the reader can count chunks for checkpoint resume without
  /// duplicating the split logic.

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
  ///
  /// Resume support: pass [startFromChunk] and [priorParts] from a checkpoint
  /// so already-finished chunks are not re-sent to the API. [onChunkComplete]
  /// fires after each successful chunk with the durable partial text.
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
    final chunks = _chunk(rawText);
    if (chunks.isEmpty) return '';

    final total = chunks.length;
    final safeStart = startFromChunk.clamp(0, total);
    final translatedParts = <String>[
      ...priorParts.take(safeStart),
    ];

    // Surface any already-finished work immediately so the UI is not blank
    // while the next chunk is still in flight.
    if (translatedParts.isNotEmpty) {
      onProgress(safeStart, total, translatedParts.join('\n\n'));
    }

    for (var i = safeStart; i < total; i++) {
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
      final joined = translatedParts.join('\n\n');
      onProgress(i + 1, total, joined);
      onChunkComplete?.call(i + 1, total, joined);
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

