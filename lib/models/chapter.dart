import 'package:hive_ce/hive.dart';

/// A single saved chapter: raw source text + English translation,
/// plus enough link/context info to resume reading and keep navigating.
class Chapter {
  /// Stable id — always the chapter URL.
  final String id;
  final String url;
  final String bookTitle;
  final String chapterTitle;
  final String rawText;
  final String translatedText;
  final double scrollPosition;
  final DateTime savedAt;
  final DateTime lastReadAt;
  final String sourceDomain;
  final String? prevUrl;
  final String? nextUrl;
  final String? tocUrl;

  Chapter({
    required this.id,
    required this.url,
    required this.bookTitle,
    required this.chapterTitle,
    required this.rawText,
    required this.translatedText,
    this.scrollPosition = 0,
    required this.savedAt,
    required this.lastReadAt,
    required this.sourceDomain,
    this.prevUrl,
    this.nextUrl,
    this.tocUrl,
  });

  Chapter copyWith({
    String? bookTitle,
    String? chapterTitle,
    String? rawText,
    String? translatedText,
    double? scrollPosition,
    DateTime? lastReadAt,
    String? prevUrl,
    String? nextUrl,
    String? tocUrl,
  }) {
    return Chapter(
      id: id,
      url: url,
      bookTitle: bookTitle ?? this.bookTitle,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      rawText: rawText ?? this.rawText,
      translatedText: translatedText ?? this.translatedText,
      scrollPosition: scrollPosition ?? this.scrollPosition,
      savedAt: savedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      sourceDomain: sourceDomain,
      prevUrl: prevUrl ?? this.prevUrl,
      nextUrl: nextUrl ?? this.nextUrl,
      tocUrl: tocUrl ?? this.tocUrl,
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
    );
  }

  @override
  void write(BinaryWriter writer, Chapter obj) {
    writer
      ..writeByte(13)
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
      ..write(obj.tocUrl);
  }
}
