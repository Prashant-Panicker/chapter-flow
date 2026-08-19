import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chapter.dart';
import '../models/glossary_entry.dart';
import 'ai_provider.dart';

/// Central place for everything persisted on-device:
/// - Hive box "chapters" for offline raw+translated text (keyed by URL)
/// - Hive box "glossaries" for per-novel term bindings (keyed by series)
/// - SharedPreferences for last URL / continuous-translate toggle / AI provider
/// - flutter_secure_storage for the user's own API keys (per provider)
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _chaptersBoxName = 'chapters';
  static const _glossaryBoxName = 'glossaries';
  static const _keyLastUrl = 'last_url';
  static const _keyContinuousEnabled = 'continuous_translate_enabled';
  static const _keyFontSize = 'reader_font_size';
  static const _keyGistMode = 'translation_gist_mode';
  static const _keyAiProvider = 'ai_provider';

  /// Matches the clamp in both readers' text-size buttons.
  static const double minFontSize = 14;
  static const double maxFontSize = 28;
  static const double defaultFontSize = 17;

  /// Bounds prompt-building work and storage for very long novels.
  static const _maxGlossaryEntries = 1500;

  /// A term may hold a second binding only when it is a genuine homonym.
  static const _maxSensesPerTerm = 2;

  final _secureStorage = const FlutterSecureStorage();
  late Box<Chapter> _chaptersBox;
  late Box<List<dynamic>> _glossaryBox;
  bool _initialized = false;

  /// False when [init] failed and the user chose to continue anyway: every
  /// chapter/glossary call below then no-ops instead of throwing.
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChapterAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(GlossaryEntryAdapter());
    }
    _chaptersBox = await Hive.openBox<Chapter>(_chaptersBoxName);
    _glossaryBox = await Hive.openBox<List<dynamic>>(_glossaryBoxName);
    // Note: pruneAllSeries() is not called at startup to avoid silent data loss.
    // Call it explicitly if you want to enforce the retention policy.
    _initialized = true;
  }

  // ---------------- Glossary (key = series key) ----------------

  List<GlossaryEntry> glossaryFor(String seriesKey) {
    if (!_initialized) return const [];
    final raw = _glossaryBox.get(seriesKey);
    if (raw == null || raw.isEmpty) return const [];
    return raw.whereType<GlossaryEntry>().toList(growable: false);
  }

  /// Merges newly extracted terms using first-write-wins: once a term has a
  /// binding it is never overwritten, which is what makes the translation
  /// consistent across chunks and chapters.
  ///
  /// A second binding for the same term is accepted only when its [style]
  /// differs — that distinguishes a real homonym (a character *named* 朱雀 vs
  /// the 朱雀 species) from the model simply being inconsistent.
  ///
  /// Returns true if all [incoming] terms were added, or false if the glossary
  /// reached its size limit ([_maxGlossaryEntries]) and some terms were rejected.
  Future<bool> mergeGlossary(
    String seriesKey,
    List<GlossaryEntry> incoming,
  ) async {
    if (!_initialized) return false;
    if (incoming.isEmpty) return true;
    final current = glossaryFor(seriesKey).toList();
    if (current.length >= _maxGlossaryEntries) return false;

    final senses = <String, List<GlossaryEntry>>{};
    for (final entry in current) {
      senses.putIfAbsent(entry.source, () => []).add(entry);
    }
    final pinned = current.map((e) => e.pinKey).toSet();

    var added = false;
    var capacityExceeded = false;
    for (final entry in incoming) {
      if (current.length >= _maxGlossaryEntries) {
        capacityExceeded = true;
        break;
      }
      if (pinned.contains(entry.pinKey)) continue;
      final existing = senses[entry.source] ?? const <GlossaryEntry>[];
      if (existing.length >= _maxSensesPerTerm) continue;
      if (existing.any((e) => e.style == entry.style)) continue;

      current.add(entry);
      pinned.add(entry.pinKey);
      senses.putIfAbsent(entry.source, () => []).add(entry);
      added = true;
    }
    if (!added) return !capacityExceeded;
    await _glossaryBox.put(seriesKey, current);
    return !capacityExceeded;
  }

  // ---------------- Chapters (key = chapter URL / id) ----------------

  Future<void> saveChapter(Chapter chapter) async {
    if (!_initialized) return;
    await _chaptersBox.put(chapter.id, chapter);
  }

  Chapter? getChapter(String url) => _initialized ? _chaptersBox.get(url) : null;

  /// The library shows one entry per novel+site: the most recently read
  /// chapter of that series.
  List<Chapter> libraryEntries() {
    if (!_initialized) return const [];
    final latest = <String, Chapter>{};
    for (final c in _chaptersBox.values) {
      final existing = latest[c.seriesKey];
      if (existing == null || c.lastReadAt.isAfter(existing.lastReadAt)) {
        latest[c.seriesKey] = c;
      }
    }
    final list = latest.values.toList();
    list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return list;
  }

  /// Applies the one-entry-per-series rule to everything already on disk,
  /// keeping each series' last read chapter plus the one before and after it.
  Future<void> pruneAllSeries() async {
    if (!_initialized) return;
    final keep = <String>{};
    for (final entry in libraryEntries()) {
      keep.add(entry.id);
      final prev = entry.prevUrl;
      if (prev != null && prev.isNotEmpty) keep.add(prev);
      final next = entry.nextUrl;
      if (next != null && next.isNotEmpty) keep.add(next);
    }
    final stale = _chaptersBox.values
        .where((c) => !keep.contains(c.id))
        .map((c) => c.id)
        .toList();
    if (stale.isEmpty) return;
    await _chaptersBox.deleteAll(stale);
  }

  Future<void> deleteSeries(String seriesKey) async {
    if (!_initialized) return;
    final ids = _chaptersBox.values
        .where((c) => c.seriesKey == seriesKey)
        .map((c) => c.id)
        .toList();
    if (ids.isNotEmpty) await _chaptersBox.deleteAll(ids);
    await _glossaryBox.delete(seriesKey);
  }

  /// Backfills the English novel name once it has been translated.
  Future<void> setSeriesEnglishTitle(
    String seriesKey,
    String englishTitle,
  ) async {
    if (!_initialized) return;
    for (final c in _chaptersBox.values.toList()) {
      if (c.seriesKey != seriesKey || c.bookTitleEnglish == englishTitle) {
        continue;
      }
      await _chaptersBox.put(
        c.id,
        c.copyWith(bookTitleEnglish: englishTitle),
      );
    }
  }

  /// Backfills the English chapter heading once it has been translated.
  Future<void> setChapterEnglishTitle(String id, String englishTitle) async {
    if (!_initialized) return;
    final existing = _chaptersBox.get(id);
    if (existing == null || existing.chapterTitleEnglish == englishTitle) {
      return;
    }
    await _chaptersBox.put(
      id,
      existing.copyWith(chapterTitleEnglish: englishTitle),
    );
  }

  Future<void> touchLastRead(String url) async {
    if (!_initialized) return;
    final existing = _chaptersBox.get(url);
    if (existing == null) return;
    await _chaptersBox.put(
      url,
      existing.copyWith(lastReadAt: DateTime.now()),
    );
  }

  /// Remembers how far into a chapter you had read, stored as a 0..1
  /// fraction rather than a pixel offset so it survives a font-size change
  /// or a rotation. No-ops for a chapter that was never saved.
  Future<void> saveReadingProgress(String url, double fraction) async {
    if (!_initialized) return;
    final existing = _chaptersBox.get(url);
    if (existing == null) return;
    final clamped = fraction.clamp(0.0, 1.0);
    // Avoids a Hive write on every scroll tick.
    if ((existing.scrollPosition - clamped).abs() < 0.01) return;
    await _chaptersBox.put(
      url,
      existing.copyWith(scrollPosition: clamped),
    );
  }

  // ---------------- Preferences ----------------

  Future<void> setLastUrl(String url) async {
    if (url.isEmpty || url == 'about:blank') return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastUrl, url);
  }

  Future<String?> getLastUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_keyLastUrl);
    if (v == null || v.isEmpty || v == 'about:blank') return null;
    return v;
  }

  Future<void> setContinuousEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyContinuousEnabled, enabled);
  }

  Future<bool> getContinuousEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyContinuousEnabled) ?? false;
  }

  /// Text size is a reader-wide preference, shared by the live and offline
  /// readers, so it never has to be set twice.
  Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFontSize, size);
  }

  Future<double> getFontSize() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_keyFontSize) ?? defaultFontSize;
    return v.clamp(minFontSize, maxFontSize);
  }

  /// When true, chapters are translated in condensed (gist) style instead of
  /// full literary output. Affects new translations only.
  Future<void> setGistMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyGistMode, enabled);
  }

  Future<bool> getGistMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyGistMode) ?? false;
  }

  // ---------------- AI provider selection ----------------

  Future<void> setAiProvider(AiProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAiProvider, provider.id);
  }

  Future<AiProvider> getAiProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return AiProviderX.fromId(prefs.getString(_keyAiProvider));
  }

  // ---------------- API keys (secure, device-only, per provider) ----------------

  /// Convenience: key for the currently selected provider.
  Future<void> setApiKey(String key) async {
    final provider = await getAiProvider();
    await setApiKeyFor(provider, key);
  }

  Future<String?> getApiKey() async {
    final provider = await getAiProvider();
    return getApiKeyFor(provider);
  }

  Future<bool> hasApiKey() async {
    final k = await getApiKey();
    return k != null && k.isNotEmpty;
  }

  Future<void> clearApiKey() async {
    final provider = await getAiProvider();
    await clearApiKeyFor(provider);
  }

  Future<void> setApiKeyFor(AiProvider provider, String key) async {
    await _secureStorage.write(key: provider.secureStorageKey, value: key);
  }

  Future<String?> getApiKeyFor(AiProvider provider) async {
    return _secureStorage.read(key: provider.secureStorageKey);
  }

  Future<bool> hasApiKeyFor(AiProvider provider) async {
    final k = await getApiKeyFor(provider);
    return k != null && k.isNotEmpty;
  }

  Future<void> clearApiKeyFor(AiProvider provider) async {
    await _secureStorage.delete(key: provider.secureStorageKey);
  }
}
