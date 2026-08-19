import 'package:hive_ce/hive.dart';

/// A single saved chapter: raw source text + English translation,
/// plus enough link/context info to resume reading and keep navigating.
class Chapter {
  /// Stable id — always the chapter URL.
  final String id;
  final String url;
  final String bookTitle;

  /// Book title rendered in English. Falls back to [bookTitle] when the
  /// source title could not be translated.
  final String? bookTitleEnglish;
  final String chapterTitle;

  /// Chapter heading rendered in English, when it could be translated.
  final String? chapterTitleEnglish;

  /// Chapter number parsed from the page (e.g. "1024"), when detectable.
  final String? chapterNumber;
  final String rawText;
  final String translatedText;
  final double scrollPosition;
  final DateTime savedAt;
  final DateTime lastReadAt;
  final String sourceDomain;
  final String? prevUrl;
  final String? nextUrl;
  final String? tocUrl;

  /// How many source chunks have been fully translated into [translatedText].
  ///
  /// 0 means either not started, or the chapter is fully done (existing
  /// chapters and finished translations). A positive value means an
  /// in-progress checkpoint: [translatedText] holds the first N chunks and
  /// translation can resume from chunk N without re-sending them.
  final int completedSourceChunks;

  /// The exact per-chunk translated text backing a checkpoint.
  ///
  /// [translatedText] is these parts joined with `\n\n`, but a chunk's own
  /// text may itself contain paragraph breaks, so re-splitting the joined
  /// text on `\n\n` can't recover the original chunk boundaries. Only
  /// meaningful when [completedSourceChunks] is greater than 0.
  final List<String>? checkpointParts;

  Chapter({
    required this.id,
    required this.url,
    required this.bookTitle,
    this.bookTitleEnglish,
    required this.chapterTitle,
    this.chapterTitleEnglish,
    this.chapterNumber,
    required this.rawText,
    required this.translatedText,
    this.scrollPosition = 0,
    required this.savedAt,
    required this.lastReadAt,
    required this.sourceDomain,
    this.prevUrl,
    this.nextUrl,
    this.tocUrl,
    this.completedSourceChunks = 0,
    this.checkpointParts,
  });

  /// True when [translatedText] is a finished translation, not a checkpoint.
  bool get isFullyTranslated =>
      translatedText.isNotEmpty && completedSourceChunks == 0;

  /// A novel is identified by its source-language title plus the site it is
  /// hosted on, so the same novel on two sites stays two library entries.
  static String seriesKeyFor(String sourceDomain, String bookTitle) {
    final host = sourceDomain.trim().toLowerCase();
    final title = bookTitle.trim().toLowerCase();
    return '$host::$title';
  }

  String get seriesKey => seriesKeyFor(sourceDomain, bookTitle);

  /// Best available English-ish name for the novel.
  String get displayBookTitle {
    final english = bookTitleEnglish?.trim();
    if (english != null && english.isNotEmpty) return english;
    return bookTitle.trim().isEmpty ? sourceDomain : bookTitle.trim();
  }

  /// Chapter heading for UI. Prefers the translated heading, then the plain
  /// "Chapter N" form, and only falls back to the source heading when neither
  /// is available.
  String get displayChapterTitle {
    final english = chapterTitleEnglish?.trim();
    if (english != null && english.isNotEmpty) return english;
    final number = chapterNumber?.trim();
    if (number != null && number.isNotEmpty) return 'Chapter $number';
    return chapterTitle.trim();
  }

  Chapter copyWith({
    String? bookTitle,
    String? bookTitleEnglish,
    String? chapterTitle,
    String? chapterTitleEnglish,
    String? chapterNumber,
    String? rawText,
    String? translatedText,
    double? scrollPosition,
    DateTime? lastReadAt,
    String? prevUrl,
    String? nextUrl,
    String? tocUrl,
    int? completedSourceChunks,
    List<String>? checkpointParts,
  }) {
    final chunks = completedSourceChunks ?? this.completedSourceChunks;
    return Chapter(
      id: id,
      url: url,
      bookTitle: bookTitle ?? this.bookTitle,
      bookTitleEnglish: bookTitleEnglish ?? this.bookTitleEnglish,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      chapterTitleEnglish: chapterTitleEnglish ?? this.chapterTitleEnglish,
      chapterNumber: chapterNumber ?? this.chapterNumber,
      rawText: rawText ?? this.rawText,
      translatedText: translatedText ?? this.translatedText,
      scrollPosition: scrollPosition ?? this.scrollPosition,
      savedAt: savedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      sourceDomain: sourceDomain,
      prevUrl: prevUrl ?? this.prevUrl,
      nextUrl: nextUrl ?? this.nextUrl,
      tocUrl: tocUrl ?? this.tocUrl,
      completedSourceChunks: chunks,
      // A zero chunk count means there is no checkpoint, so the parts go too.
      checkpointParts:
          chunks > 0 ? (checkpointParts ?? this.checkpointParts) : null,
    );
  }
}

/// Hand-written TypeAdapter so the project builds without running
/// build_runner / code generation. Field order below IS the on-disk
/// schema — only ever append new fields, never reorder or remove.
class ChapterAdapter extends TypeAdapter<Chapter> {
  @override
  final int typeId = 0;

  @override
  Chapter read(BinaryReader reader) {
    final numFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numFields; i++) reader.readByte(): reader.read(),
    };
    return Chapter(
      id: fields[0] as String,
      url: fields[1] as String,
      bookTitle: fields[2] as String,
      chapterTitle: fields[3] as String,
      rawText: fields[4] as String,
      translatedText: fields[5] as String,
      scrollPosition: (fields[6] as num?)?.toDouble() ?? 0,
      savedAt: fields[7] as DateTime,
      lastReadAt: fields[8] as DateTime,
      sourceDomain: fields[9] as String,
      prevUrl: fields[10] as String?,
      nextUrl: fields[11] as String?,
      tocUrl: fields[12] as String?,
      bookTitleEnglish: fields[13] as String?,
      chapterNumber: fields[14] as String?,
      chapterTitleEnglish: fields[15] as String?,
      completedSourceChunks: fields[16] as int? ?? 0,
      checkpointParts: (fields[17] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, Chapter obj) {
    writer
      ..writeByte(18)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.bookTitle)
      ..writeByte(3)
      ..write(obj.chapterTitle)
      ..writeByte(4)
      ..write(obj.rawText)
      ..writeByte(5)
      ..write(obj.translatedText)
      ..writeByte(6)
      ..write(obj.scrollPosition)
      ..writeByte(7)
      ..write(obj.savedAt)
      ..writeByte(8)
      ..write(obj.lastReadAt)
      ..writeByte(9)
      ..write(obj.sourceDomain)
      ..writeByte(10)
      ..write(obj.prevUrl)
      ..writeByte(11)
      ..write(obj.nextUrl)
      ..writeByte(12)
      ..write(obj.tocUrl)
      ..writeByte(13)
      ..write(obj.bookTitleEnglish)
      ..writeByte(14)
      ..write(obj.chapterNumber)
      ..writeByte(15)
      ..write(obj.chapterTitleEnglish)
      ..writeByte(16)
      ..write(obj.completedSourceChunks)
      ..writeByte(17)
      ..write(obj.checkpointParts);
  }
}
