import 'package:hive_ce/hive.dart';

/// How a term must be rendered in English. Closed on purpose: the translator
/// prompt branches on this, so it cannot be free-form.
enum GlossaryStyle {
  /// Personal names of characters, and proper names of places / sects /
  /// organisations. Written as Pinyin, never translated literally.
  pinyin,

  /// Everything else — species, races, realms, techniques, artifacts, titles.
  /// Written as natural English.
  english,
}

/// One pinned translation binding for a novel.
///
/// [type] is deliberately free-form: the model describes what the term is in
/// its own words ("spirit beast species", "sword sect", "protagonist"), which
/// keeps genre-specific concepts from being crushed into a fixed taxonomy.
/// Nothing branches on it — it is context handed back to the model.
class GlossaryEntry {
  final String source;
  final String english;
  final GlossaryStyle style;
  final String type;

  const GlossaryEntry({
    required this.source,
    required this.english,
    required this.style,
    required this.type,
  });

  /// Identity used for de-duplication.
  String get pinKey => '$source|${english.toLowerCase()}';

  /// Parses one model-produced entry, returning null for anything malformed.
  /// Extraction is best-effort, so bad rows are dropped rather than fatal.
  static GlossaryEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final source = (raw['source'] as Object?)?.toString().trim() ?? '';
    final english = (raw['english'] as Object?)?.toString().trim() ?? '';
    final styleText =
        (raw['style'] as Object?)?.toString().trim().toLowerCase() ?? '';
    final type = (raw['type'] as Object?)?.toString().trim() ?? '';

    if (source.isEmpty || english.isEmpty) return null;
    // A source term must actually be source-language text.
    if (!RegExp(r'[^\x00-\x7F]').hasMatch(source)) return null;
    if (source.length > 40 || english.length > 80) return null;
    // The rendering has to be usable as English prose.
    if (RegExp(r'[\u4e00-\u9fff]').hasMatch(english)) return null;

    final style =
        styleText == 'pinyin' ? GlossaryStyle.pinyin : GlossaryStyle.english;
    return GlossaryEntry(
      source: source,
      english: english,
      style: style,
      type: type.length > 60 ? type.substring(0, 60) : type,
    );
  }
}

/// Hand-written adapter, matching the project's no-codegen convention.
/// Field order is the on-disk schema — only ever append.
class GlossaryEntryAdapter extends TypeAdapter<GlossaryEntry> {
  @override
  final int typeId = 1;

  @override
  GlossaryEntry read(BinaryReader reader) {
    final numFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numFields; i++) reader.readByte(): reader.read(),
    };
    final styleIndex = fields[2] as int? ?? GlossaryStyle.english.index;
    return GlossaryEntry(
      source: fields[0] as String,
      english: fields[1] as String,
      style: styleIndex >= 0 && styleIndex < GlossaryStyle.values.length
          ? GlossaryStyle.values[styleIndex]
          : GlossaryStyle.english,
      type: fields[3] as String? ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, GlossaryEntry obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.source)
      ..writeByte(1)
      ..write(obj.english)
      ..writeByte(2)
      ..write(obj.style.index)
      ..writeByte(3)
      ..write(obj.type);
  }
}
