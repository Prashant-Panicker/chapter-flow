# ChapterFlow

Site-aware novel reader: manual WebView for login/CAPTCHA, an app-owned
Prev / TOC / Next reader chrome that never disappears, and a "Continuous
translate" toggle that keeps translating chapter-after-chapter as you tap
Next — via the Moonshot (Kimi) API, called directly from the device with
your own key.

## Setup

Android scaffolding is committed, so Android needs no generation step:

```bash
flutter pub get
flutter run
```

There is no `ios/` folder. To run on iOS, generate it first — it contains
no product logic:

```bash
flutter create --org com.example --project-name chapterflow --platforms=ios .
```

Pushing to `main` (or running the workflow manually) builds a release APK
via `.github/workflows/build-apk.yml`, uploaded as the
`chapterflow-release-apk` artifact. Doc-only commits are skipped.

## App icon

The launcher icon is generated, not committed by hand, so the per-density
`mipmap-*` output can never drift from the artwork. Two pre-cropped 1024px
squares live in `assets/icon/`:

| File | Used for |
| --- | --- |
| `app_icon.png` | legacy launcher icon — tight crop |
| `app_icon_foreground.png` | adaptive foreground — wider crop, so the artwork sits inside the mask's safe zone and can't be clipped |

The build runs `dart run flutter_launcher_icons` before `flutter build`, so
every CI run regenerates them. Run that same command locally after changing
either asset.

## First run

1. Open the **Browser** tab, navigate to your novel site, log in / pass any
   CAPTCHA manually — this app never automates that.
2. Go to **Settings** and paste your Moonshot API key (`https://api.moonshot.ai`).
   It's stored only in secure on-device storage.
3. Navigate to a chapter, tap **Enter Reader**.
4. Turn on **Continuous translate**. Tap **Next** to keep going — each
   chapter is extracted, translated in progressive chunks, and saved
   offline automatically, while the following chapter is prefetched and
   translated in the background.

## Library

One entry per novel per site, not per chapter. The library key is
`sourceDomain::bookTitle`, and each card shows the **last chapter you
actually read** — prefetched-but-unread chapters are stored with an epoch
timestamp so they never displace it. Older chapters of the same novel are
pruned on save and on startup.

Cards show the English novel name, the chapter number, and the source URL
(shortened to `host/…/segment` when long). Swipe or tap the delete icon to
remove a novel; that clears its chapters and its glossary.

Titles come off the page in Chinese and are translated on demand, then
persisted. The library backfills any that are still missing the next time
you open it.

## How translation stays consistent

The hard problem with chapter-at-a-time translation is drift: 朱雀 renders
as "Zhuque" in one chapter and "Vermillion Bird" in the next. ChapterFlow
keeps a **per-novel glossary** to pin that down.

**The naming rule.** Personal names of characters, and proper names of
places, sects, clans and organisations, are written in Pinyin. Everything
else — species, races, cultivation realms, techniques, artifacts, pills,
formations, titles, ranks — is written in natural English. A word that
names a *kind of thing* is English even when it looks like a name, so
「青云是朱雀」 becomes "Qingyun is a Vermillion Bird".

**How it works.**

- Each entry is `{ source, english, style, type }`. `style` is a closed
  enum (`pinyin` | `english`) that the prompt branches on; `type` is a
  short free-form description the model writes itself ("protagonist",
  "spirit beast species"), which avoids forcing genre-specific concepts
  into a fixed taxonomy.
- Extraction is a separate JSON call that runs **alongside chunk 1**, never
  before it, so pinning terms costs no perceived delay. It bypasses the
  translation queue, so a rate-limited glossary call can't stall a chapter,
  and every failure path returns empty rather than throwing.
- Bindings are **first-write-wins** — once a term has a rendering it is
  never overwritten. A second binding for the same term is accepted only
  when its `style` differs, which distinguishes a genuine homonym (a
  character *named* 朱雀 vs the 朱雀 species) from the model simply being
  inconsistent.
- Only bindings whose source text literally appears in the current chunk
  are injected into that chunk's prompt (longest first, capped at 60). That
  keeps prompts small no matter how long the novel gets.
- The last ~400 characters of the previous chunk's English are carried
  forward as read-only context for tone and pronoun continuity.
- Prefetch builds the next chapter's glossary while it's still prefetching,
  and both paths read the glossary from storage each chunk, so discoveries
  are shared automatically.

Glossaries outlive chapter pruning — they're the long-lived asset. They're
deleted only when you delete the novel from the library.

## Project layout

```
lib/
  main.dart                     # bottom-nav shell: Browser / Library / Settings
  theme/app_theme.dart          # dark, reading-first Material 3 theme
  models/
    chapter.dart                # Hive (hive_ce) model + hand-written adapter (no codegen)
    glossary_entry.dart         # per-novel term binding + adapter
  services/
    storage_service.dart        # Hive boxes + SharedPreferences + secure storage
    extraction_js.dart          # JS run in-page to pull body/title/number/prev/next/toc
    js_result.dart              # unwraps evaluateJavascript's platform-dependent return shape
    translation_service.dart    # chunked Moonshot/Kimi calls, glossary, cancellable, retrying
  screens/
    browser_screen.dart         # user-driven WebView + "Enter Reader"
    reader_screen.dart          # owned Prev/TOC/Next chrome + translate pipeline
    offline_reader_screen.dart  # reopen a saved chapter without the WebView
    library_screen.dart         # saved novels, one card per novel+site
    settings_screen.dart        # API key, clear cache, about
  widgets/
    reader_nav_bar.dart         # the persistent bottom nav bar itself
```

## Notes / known follow-ups

- Extraction heuristics in `extraction_js.dart` cover common CN novel-site
  selectors/link text, including book title, chapter heading and chapter
  number (Arabic and Chinese numerals). Add site-specific selectors there
  as you hit sites that don't match.
- The library and glossary key on the extracted `bookTitle`. If a site
  reports a slightly different novel name on some pages, a novel can
  silently split into two entries — worth watching on the first long read.
- Hive adapters are hand-written, so field order **is** the on-disk schema:
  only ever append fields, never reorder or remove them.
- Uses `hive_ce`/`hive_ce_flutter` (not the unmaintained `hive`/`hive_flutter`)
  for Dart 3 / current-Flutter compatibility — same API, different import.
- Nothing here automates CAPTCHA, login, or bulk scraping, per the
  product's non-goals.
