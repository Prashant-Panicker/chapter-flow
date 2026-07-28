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
  }

  // ---------------- Chapters (key = chapter URL / id) ----------------

  Future<void> saveChapter(Chapter chapter) async {
    await _chaptersBox.put(chapter.id, chapter);
  }

  Chapter? getChapter(String url) => _chaptersBox.get(url);

  List<Chapter> allChapters() {
    final list = _chaptersBox.values.toList();
    list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return list;
  }

  /// Group chapters by bookTitle for a simple library hierarchy.
  Map<String, List<Chapter>> chaptersByBook() {
    final map = <String, List<Chapter>>{};
    for (final c in _chaptersBox.values) {
      map.putIfAbsent(c.bookTitle, () => []).add(c);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.savedAt.compareTo(b.savedAt));
    }
    return map;
  }

  Future<void> deleteChapter(String url) async {
    await _chaptersBox.delete(url);
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
