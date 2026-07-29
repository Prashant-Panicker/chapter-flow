import 'package:flutter/material.dart';

import '../main.dart' show rootTabIndex;
import '../models/chapter.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/reader_nav_bar.dart';

enum _OfflineViewMode { english, bilingual, source }

class OfflineReaderScreen extends StatefulWidget {
  const OfflineReaderScreen({super.key, required this.chapter});

  final Chapter chapter;

  @override
  State<OfflineReaderScreen> createState() => _OfflineReaderScreenState();
}

class _OfflineReaderScreenState extends State<OfflineReaderScreen> {
  _OfflineViewMode _mode = _OfflineViewMode.english;
  double _fontSize = 17;
  bool _continuousEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadContinuousPref();
  }

  Future<void> _loadContinuousPref() async {
    final enabled = await StorageService.instance.getContinuousEnabled();
    if (!mounted) return;
    setState(() => _continuousEnabled = enabled);
  }

  Future<void> _setContinuousEnabled(bool enabled) async {
    setState(() => _continuousEnabled = enabled);
    await StorageService.instance.setContinuousEnabled(enabled);
  }

  /// Follows a saved link. A chapter that is still in the library opens
  /// instantly and stays offline; anything else needs the live page, which
  /// only exists on the Browser tab.
  Future<void> _follow(String? url, {required String label}) async {
    if (url == null || url.isEmpty) return;

    final saved = StorageService.instance.getChapter(url);
    if (saved != null && saved.translatedText.isNotEmpty) {
      await StorageService.instance.touchLastRead(url);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => OfflineReaderScreen(chapter: saved)),
      );
      return;
    }

    await StorageService.instance.setLastUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$label is not saved offline — opening in Browser.'),
          duration: const Duration(seconds: 3),
        ),
      );
    Navigator.of(context).popUntil((route) => route.isFirst);
    rootTabIndex.value = 0;
  }

  String get _text {
    final c = widget.chapter;
    switch (_mode) {
      case _OfflineViewMode.english:
        return c.translatedText.isEmpty
            ? '(No translation saved for this chapter.)'
            : c.translatedText;
      case _OfflineViewMode.source:
        return c.rawText;
      case _OfflineViewMode.bilingual:
        final eng = c.translatedText.isEmpty
            ? '(No translation saved.)'
            : c.translatedText;
        return '${c.rawText}\n\n──── English ────\n\n$eng';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        toolbarHeight: 64,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.chapter.displayChapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              widget.chapter.displayBookTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Smaller text',
            onPressed: () =>
                setState(() => _fontSize = (_fontSize - 1).clamp(14, 28)),
            icon: const Icon(Icons.text_decrease, size: 20),
          ),
          IconButton(
            tooltip: 'Larger text',
            onPressed: () =>
                setState(() => _fontSize = (_fontSize + 1).clamp(14, 28)),
            icon: const Icon(Icons.text_increase, size: 20),
          ),
          PopupMenuButton<_OfflineViewMode>(
            initialValue: _mode,
            onSelected: (m) => setState(() => _mode = m),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _OfflineViewMode.english,
                child: Text('English only'),
              ),
              PopupMenuItem(
                value: _OfflineViewMode.bilingual,
                child: Text('Bilingual'),
              ),
              PopupMenuItem(
                value: _OfflineViewMode.source,
                child: Text('Source'),
              ),
            ],
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
      ),
      body: SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Text(
                _text,
                style: TextStyle(
                  fontSize: _fontSize,
                  height: 1.7,
                  color: AppTheme.textPrimary,
                  letterSpacing: 0.15,
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: ReaderNavBar(
        hasPrev: (widget.chapter.prevUrl ?? '').isNotEmpty,
        hasNext: (widget.chapter.nextUrl ?? '').isNotEmpty,
        hasToc: (widget.chapter.tocUrl ?? '').isNotEmpty,
        onPrev: () => _follow(widget.chapter.prevUrl, label: 'Previous chapter'),
        onNext: () => _follow(widget.chapter.nextUrl, label: 'Next chapter'),
        onToc: () => _follow(widget.chapter.tocUrl, label: 'Contents'),
        autoTranslateEnabled: _continuousEnabled,
        autoTranslateBusy: false,
        onAutoTranslateChanged: _setContinuousEnabled,
      ),
    );
  }
}
