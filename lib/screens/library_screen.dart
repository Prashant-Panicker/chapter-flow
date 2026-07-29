import 'package:flutter/material.dart';

import '../models/chapter.dart';
import '../services/storage_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';
import 'offline_reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late List<Chapter> _chapters;

  /// Series we already tried to translate, so a failed lookup is not retried
  /// on every rebuild.
  final Set<String> _titleAttempts = <String>{};
  bool _translatingTitles = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refresh();
  }

  void _refresh() {
    setState(() => _chapters = StorageService.instance.libraryEntries());
    _backfillEnglishTitles();
  }

  /// Cards and the offline reader must read in English. Anything still stored
  /// under its source-language name (older entries, or entries saved while
  /// translation was unavailable) gets translated once and persisted.
  Future<void> _backfillEnglishTitles() async {
    if (_translatingTitles) return;
    final pending = _chapters
        .where((c) =>
            !_titleAttempts.contains(c.seriesKey) &&
            (_needsTranslation(c.bookTitle, c.bookTitleEnglish) ||
                _needsTranslation(c.chapterTitle, c.chapterTitleEnglish)))
        .toList();
    if (pending.isEmpty) return;

    _translatingTitles = true;
    try {
      final apiKey = await StorageService.instance.getApiKey();
      if (apiKey == null || apiKey.isEmpty) return;
      final translator = TranslationService(apiKey: apiKey);
      var changed = false;
      for (final chapter in pending) {
        _titleAttempts.add(chapter.seriesKey);
        if (_needsTranslation(chapter.bookTitle, chapter.bookTitleEnglish)) {
          final english = await translator.translateTitle(chapter.bookTitle);
          if (english.isNotEmpty) {
            await StorageService.instance
                .setSeriesEnglishTitle(chapter.seriesKey, english);
            changed = true;
          }
        }
        if (_needsTranslation(
          chapter.chapterTitle,
          chapter.chapterTitleEnglish,
        )) {
          final english = await translator.translateTitle(chapter.chapterTitle);
          if (english.isNotEmpty) {
            await StorageService.instance
                .setChapterEnglishTitle(chapter.id, english);
            changed = true;
          }
        }
      }
      if (!mounted || !changed) return;
      setState(() => _chapters = StorageService.instance.libraryEntries());
    } catch (_) {
      // Titles stay in the source language until the next visit.
    } finally {
      _translatingTitles = false;
    }
  }

  static bool _needsTranslation(String source, String? english) =>
      (english?.trim().isEmpty ?? true) &&
      source.trim().isNotEmpty &&
      RegExp(r'[^\x00-\x7F]').hasMatch(source);

  String _cardTitle(Chapter chapter) {
    final novel = chapter.displayBookTitle.trim();
    final number = chapter.chapterNumber?.trim() ?? '';
    if (novel.isEmpty) return chapter.url;
    if (number.isNotEmpty) return '$novel — Chapter $number';
    // No number detected: use the English heading rather than leaking the
    // source-language title onto the card.
    final heading = chapter.chapterTitleEnglish?.trim() ?? '';
    return heading.isEmpty ? novel : '$novel — $heading';
  }

  /// Shows the whole URL when it is short, otherwise host + last segment.
  String _urlSubtext(String url) {
    if (url.length <= 52) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return '${url.substring(0, 49)}…';
    final segments =
        uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    final tail = segments.isEmpty ? '' : segments.last;
    final short = tail.isEmpty ? uri.host : '${uri.host}/…/$tail';
    return short.length <= 52 ? short : '${short.substring(0, 51)}…';
  }

  Future<void> _delete(Chapter chapter) async {
    await StorageService.instance.deleteSeries(chapter.seriesKey);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _confirmDelete(Chapter chapter) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          'This deletes the saved chapter for "${chapter.displayBookTitle}".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _delete(chapter);
  }

  @override
  Widget build(BuildContext context) {
    if (_chapters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.collections_bookmark_outlined,
                size: 48,
                color: AppTheme.textSecondary.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 16),
              const Text(
                'No saved chapters',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppTheme.accent,
      backgroundColor: AppTheme.surface,
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _chapters.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final chapter = _chapters[index];
          return Dismissible(
            key: ValueKey(chapter.seriesKey),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.delete_outline, color: AppTheme.danger),
            ),
            onDismissed: (_) => _delete(chapter),
            child: Material(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () async {
                  await StorageService.instance.touchLastRead(chapter.url);
                  if (!context.mounted) return;
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => OfflineReaderScreen(chapter: chapter),
                    ),
                  );
                  if (!mounted) return;
                  _refresh();
                },
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _cardTitle(chapter),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _urlSubtext(chapter.url),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.textSecondary
                                    .withValues(alpha: 0.85),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _confirmDelete(chapter),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
