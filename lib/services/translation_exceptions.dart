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
      'No API key found. Add your key in Settings.';
}

class ApiKeyValidationException implements Exception {
  ApiKeyValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How chapter text is rendered by the translator.
enum TranslationMode {
  /// Full paragraph-by-paragraph literary translation.
  full,

  /// Condensed narrative: events, dialogue, and context kept; filler cut.
  gist,
}
