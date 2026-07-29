import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chapter.dart';

/// Central place for everything persisted on-device:
/// - Hive box "chapters" for offline raw+translated text (keyed by URL)
/// - SharedPreferences for last URL / continuous-translate toggle
/// - flutter_secure_storage for the user's own Moonshot API key
class StorageService {
  StorageService._();
  static final StorageService instance = StorageService._();

  static const _chaptersBoxName = 'chapters';
  static const _keyLastUrl = 'last_url';
  static const _keyContinuousEnabled = 'continuous_translate_enabled';
  static const _secureApiKeyKey = 'moonshot_api_key';

  final _secureStorage = const FlutterSecureStorage();
  late Box<Chapter> _chaptersBox;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(ChapterAdapter());
    }
    _chaptersBox = await Hive.openBox<Chapter>(_chaptersBoxName);
    _initialized = true;
    await pruneAllSeries();
  }

  // ---------------- Chapters (key = chapter URL / id) ----------------

  Future<void> saveChapter(Chapter chapter) async {
    await _chaptersBox.put(chapter.id, chapter);
  }

  Chapter? getChapter(String url) => _chaptersBox.get(url);

  /// The library shows one entry per novel+site: the most recently read
  /// chapter of that series.
  List<Chapter> libraryEntries() {
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

  /// Drops every stored chapter of [seriesKey] except [keepIds], so a series
  /// never keeps more than the chapter being read plus its prefetched next.
  Future<void> pruneSeries(
    String seriesKey, {
    required Set<String> keepIds,
  }) async {
    final stale = _chaptersBox.values
        .where((c) => c.seriesKey == seriesKey && !keepIds.contains(c.id))
        .map((c) => c.id)
        .toList();
    if (stale.isEmpty) return;
    await _chaptersBox.deleteAll(stale);
  }

  /// Applies the one-entry-per-series rule to everything already on disk,
  /// keeping each series' last read chapter plus its prefetched next one.
  Future<void> pruneAllSeries() async {
    final keep = <String>{};
    for (final entry in libraryEntries()) {
      keep.add(entry.id);
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
    final ids = _chaptersBox.values
        .where((c) => c.seriesKey == seriesKey)
        .map((c) => c.id)
        .toList();
    if (ids.isEmpty) return;
    await _chaptersBox.deleteAll(ids);
  }

  /// Backfills the English novel name once it has been translated.
  Future<void> setSeriesEnglishTitle(
    String seriesKey,
    String englishTitle,
  ) async {
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
    final existing = _chaptersBox.get(url);
    if (existing == null) return;
    await _chaptersBox.put(
      url,
      existing.copyWith(lastReadAt: DateTime.now()),
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

  // ---------------- API key (secure, device-only) ----------------

  Future<void> setApiKey(String key) async {
    await _secureStorage.write(key: _secureApiKeyKey, value: key);
  }

  Future<String?> getApiKey() async {
    return _secureStorage.read(key: _secureApiKeyKey);
  }

  Future<bool> hasApiKey() async {
    final k = await getApiKey();
    return k != null && k.isNotEmpty;
  }

  Future<void> clearApiKey() async {
    await _secureStorage.delete(key: _secureApiKeyKey);
  }
}
