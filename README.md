# ChapterFlow

Site-aware novel reader: manual WebView for login/CAPTCHA, an app-owned
Prev / TOC / Next reader chrome that never disappears, and a "Continuous
translate" toggle that keeps translating chapter-after-chapter as you tap
Next — via the Moonshot (Kimi) API, called directly from the device with
your own key.

## Setup

This repo ships only `lib/` and `pubspec.yaml` (no `android/`/`ios/`
scaffolding, since that's generated tooling, not hand-written code).

```bash
flutter create --org com.example --project-name chapterflow .
# then let it merge in without overwriting lib/ and pubspec.yaml
flutter pub get
flutter run
```

If `flutter create .` complains about existing files, run it in a fresh
empty folder first, then copy this `lib/` and `pubspec.yaml` over the
generated ones.

## First run

1. Open the **Browser** tab, navigate to your novel site, log in / pass any
   CAPTCHA manually — this app never automates that.
2. Go to **Settings** and paste your Moonshot API key (`https://api.moonshot.ai`).
   It's stored only in secure on-device storage.
3. Navigate to a chapter, tap **Enter Reader**.
4. Turn on **Continuous translate**. Tap **Next** to keep going — each
   chapter is extracted, translated in progressive chunks, and saved
   offline automatically.

## Project layout

```
lib/
  main.dart                     # bottom-nav shell: Browser / Library / Settings
  theme/app_theme.dart          # dark, reading-first Material 3 theme
  models/chapter.dart           # Hive (hive_ce) model + hand-written adapter (no codegen needed)
  services/
    storage_service.dart        # Hive + SharedPreferences + secure storage
    extraction_js.dart          # JS run in-page to pull body/prev/next/toc
    js_result.dart              # unwraps evaluateJavascript's platform-dependent return shape
    translation_service.dart    # Chunked Moonshot/Kimi calls, cancellable, with retry
  screens/
    browser_screen.dart         # user-driven WebView + "Enter Reader"
    reader_screen.dart          # owned Prev/TOC/Next chrome + translate pipeline
    offline_reader_screen.dart  # reopen a saved chapter without the WebView
    library_screen.dart         # offline saved chapters
    settings_screen.dart        # API key, clear cache, about
  widgets/
    reader_nav_bar.dart         # the persistent bottom nav bar itself
```

## Notes / known follow-ups

- Extraction heuristics in `extraction_js.dart` cover common CN novel-site
  selectors/link text; add site-specific selectors there as you hit sites
  that don't match.
- No native `android/`/`ios/` folders are included — generate them with
  `flutter create` as noted above, they contain no product logic.
- Uses `hive_ce`/`hive_ce_flutter` (not the unmaintained `hive`/`hive_flutter`)
  for Dart 3 / current-Flutter compatibility — same API, different import.
- Nothing here automates CAPTCHA, login, or bulk scraping, per the
  product's non-goals.
