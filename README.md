# ChapterFlow

An Android reader for Chinese web novels. You browse the site yourself in an
in-app browser, tap into the reader, and the chapter is translated to English
and saved for offline reading. Turn on continuous translate and it keeps
going chapter after chapter.

Translation uses the Moonshot (Kimi) API, called directly from your device
with your own API key.

## Requirements

- An Android device or emulator.
- A Moonshot API key. It is stored only in secure on-device storage.

## Install

Download the APK from the latest **Build APK** workflow run (artifact
`chapterflow-release-apk`), or build it yourself:

```bash
flutter pub get
flutter run
```

There is no `ios/` folder. To try it on iOS, generate one first:

```bash
flutter create --org com.example --project-name chapterflow --platforms=ios .
```

## Getting started

1. Open the **Browser** tab and navigate to your novel site. Log in and
   solve any CAPTCHA yourself — the app never automates that.
2. In **Settings**, paste your Moonshot API key.
3. Navigate to a chapter and tap **Enter Reader**.
4. Optionally turn on **Continuous translate**, then tap **Next** to keep
   reading. Each chapter is translated and saved offline as you go, and the
   following one is fetched in the background so it's ready when you reach
   it.

## Reading

The reader remembers how far into a chapter you got, so closing the app or
stepping back to an earlier chapter drops you where you stopped rather than
at the top. Position is stored as a proportion of the chapter, so it stays
right even if you change the text size afterwards.

Text size is a single setting shared by both readers — set it once.

## Library

The library holds one card per novel, showing the last chapter you actually
read. Around it the app keeps a small window — the previous chapter, the
current one, and the next — so flipping back to re-read the end of the last
chapter is instant and never costs another translation. Anything outside
that window is cleaned up so saved data doesn't grow without bound.

Opening a card gives you the same Prev / TOC / Next controls as the live
reader. A chapter that's still saved opens instantly with no connection; if
it isn't, the app hands off to the Browser tab to fetch it.

Swipe a card or tap its delete icon to remove a novel and everything stored
for it.

## Consistent names across chapters

Translating one chapter at a time normally causes drift — 朱雀 becomes
"Zhuque" in one chapter and "Vermillion Bird" in the next. ChapterFlow
builds a glossary per novel as you read and reuses it, so names stay stable.

The convention it follows: characters, places, sects, clans and
organisations are written in Pinyin; everything else — species, realms,
techniques, artifacts, pills, titles, ranks — is written in natural English.
So 「青云是朱雀」 reads as "Qingyun is a Vermillion Bird".

A novel's glossary is kept even after its chapters are cleaned up, and is
deleted only when you delete the novel.

## Scope

A reading aid, nothing more. ChapterFlow does not automate logins or
CAPTCHAs and does not bulk-download or scrape sites — it translates the page
you are on. Translations are machine-generated and will not be perfect.
