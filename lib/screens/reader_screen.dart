import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/chapter.dart';
import '../services/extraction_js.dart';
import '../services/js_result.dart';
import '../services/storage_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/reader_nav_bar.dart';

enum ReaderViewMode { english, bilingual, source }

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.url,
    required this.pageTitle,
    required this.bodyText,
    required this.webViewController,
    this.prevUrl,
    this.nextUrl,
    this.tocUrl,
  });

  final String url;
  final String pageTitle;
  final String bodyText;
  final String? prevUrl;
  final String? nextUrl;
  final String? tocUrl;
  final InAppWebViewController webViewController;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late String _url;
  late String _pageTitle;
  late String _rawText;
  String _translatedText = '';
  String? _prevUrl;
  String? _nextUrl;
  String? _tocUrl;

  ReaderViewMode _viewMode = ReaderViewMode.english;
  bool _continuousEnabled = false;
  bool _busy = false;
  bool _translating = false;
  bool _cancelRequested = false;
  int _chunkCurrent = 0;
  int _chunkTotal = 0;
  double _fontSize = 17;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
    _pageTitle = widget.pageTitle;
    _rawText = widget.bodyText;
    _prevUrl = widget.prevUrl;
    _nextUrl = widget.nextUrl;
    _tocUrl = widget.tocUrl;
    _loadPrefsAndMaybeTranslate();
  }

  Future<void> _loadPrefsAndMaybeTranslate() async {
    final enabled = await StorageService.instance.getContinuousEnabled();
    final cached = StorageService.instance.getChapter(_url);
    if (!mounted) return;
    setState(() {
      _continuousEnabled = enabled;
      if (cached != null && cached.translatedText.isNotEmpty) {
        _translatedText = cached.translatedText;
      }
    });
    if (_continuousEnabled && _translatedText.isEmpty) {
      await _startTranslation();
    }
  }

  Future<TranslationService?> _buildTranslator() async {
    final key = await StorageService.instance.getApiKey();
    if (key == null || key.isEmpty) {
      _showSnack('Add your Moonshot API key in Settings to translate.');
      return null;
    }
    return TranslationService(apiKey: key);
  }

  Future<void> _startTranslation({bool force = false}) async {
    if (_translating) return;
    if (!force && _translatedText.isNotEmpty) return;

    final translator = await _buildTranslator();
    if (translator == null) return;

    setState(() {
      _translating = true;
      _cancelRequested = false;
      _chunkCurrent = 0;
      _chunkTotal = 0;
      if (force) _translatedText = '';
    });

    try {
      final result = await translator.translateChapter(
        rawText: _rawText,
        shouldCancel: () => _cancelRequested,
        onProgress: (current, total, partial) {
          if (!mounted) return;
          setState(() {
            _chunkCurrent = current;
            _chunkTotal = total;
            _translatedText = partial;
          });
        },
      );
      if (!mounted) return;
      setState(() => _translatedText = result);
      await _saveChapter();
    } on TranslationCancelledException {
      _showSnack(
        _chunkCurrent > 0
            ? 'Cancelled after $_chunkCurrent/$_chunkTotal chunks.'
            : 'Translation cancelled.',
      );
    } on TranslationChunkFailure catch (e) {
      final retry = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Translation failed'),
          content: Text('$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Dismiss'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
      if (retry == true && mounted) {
        await _startTranslation(force: true);
        return;
      }
    } catch (e) {
      _showSnack('Translation error: $e');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  void _cancelTranslation() {
    setState(() => _cancelRequested = true);
  }

  String _guessBookTitle() {
    final parts = _pageTitle.split(RegExp(r'\s*[-–_|]\s*'));
    if (parts.length >= 2 && parts.first.trim().length > 1) {
      return parts.first.trim();
    }
    return Uri.tryParse(_url)?.host ?? 'Unknown book';
  }

  Future<void> _saveChapter() async {
    if (_translatedText.isEmpty) return;
    final uri = Uri.tryParse(_url);
    final chapter = Chapter(
      id: _url,
      url: _url,
      bookTitle: _guessBookTitle(),
      chapterTitle: _pageTitle.isEmpty ? _url : _pageTitle,
      rawText: _rawText,
      translatedText: _translatedText,
      savedAt: DateTime.now(),
      lastReadAt: DateTime.now(),
      sourceDomain: uri?.host ?? '',
      prevUrl: _prevUrl,
      nextUrl: _nextUrl,
      tocUrl: _tocUrl,
    );
    await StorageService.instance.saveChapter(chapter);
  }

  Future<void> _navigate(String targetUrl) async {
    if (_translating) _cancelTranslation();
    setState(() => _busy = true);
    try {
      await widget.webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetUrl)),
      );
      await _waitForLoadThenExtract(targetUrl);
    } catch (e) {
      _showSnack('Navigation failed: $e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waitForLoadThenExtract(String targetUrl) async {
    const maxAttempts = 25;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      try {
        final raw = await widget.webViewController
            .evaluateJavascript(source: kExtractChapterJs);
        final data = parseExtractResult(raw);
        final bodyText = (data['bodyText'] as String? ?? '').trim();
        if (bodyText.length >= 40) {
          await StorageService.instance.setLastUrl(targetUrl);
          if (!mounted) return;
          setState(() {
            _url = targetUrl;
            _pageTitle = data['pageTitle'] as String? ?? '';
            _rawText = bodyText;
            _translatedText = '';
            _prevUrl = data['prevUrl'] as String?;
            _nextUrl = data['nextUrl'] as String?;
            _tocUrl = data['tocUrl'] as String?;
            _busy = false;
          });
          final cached = StorageService.instance.getChapter(targetUrl);
          if (cached != null && cached.translatedText.isNotEmpty) {
            setState(() => _translatedText = cached.translatedText);
          } else if (_continuousEnabled) {
            await _startTranslation();
          }
          return;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _busy = false);
      _showSnack(
        'Chapter text did not appear. Return to Browser and try Enter Reader again.',
      );
    }
  }

  Future<void> _openToc() async {
    if (_tocUrl == null) {
      _showSnack('No table-of-contents link found on this page.');
      return;
    }
    await widget.webViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(_tocUrl!)),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String get _displayText {
    switch (_viewMode) {
      case ReaderViewMode.english:
        return _translatedText.isEmpty
            ? ''
            : _translatedText;
      case ReaderViewMode.source:
        return _rawText;
      case ReaderViewMode.bilingual:
        final eng = _translatedText.isEmpty
            ? '(Not translated yet)'
            : _translatedText;
        return '$_rawText\n\n──── English ────\n\n$eng';
    }
  }

  @override
  Widget build(BuildContext context) {
    final showPlaceholder = _viewMode != ReaderViewMode.source &&
        _translatedText.isEmpty &&
        !_translating;

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
              _pageTitle.isEmpty ? 'Chapter' : _pageTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              _guessBookTitle(),
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
          PopupMenuButton<ReaderViewMode>(
            initialValue: _viewMode,
            onSelected: (mode) => setState(() => _viewMode = mode),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: ReaderViewMode.english,
                child: Text('English only'),
              ),
              PopupMenuItem(
                value: ReaderViewMode.bilingual,
                child: Text('Bilingual'),
              ),
              PopupMenuItem(
                value: ReaderViewMode.source,
                child: Text('Source'),
              ),
            ],
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          // Continuous translate control — compact status strip
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            decoration: const BoxDecoration(
              color: AppTheme.surface,
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _continuousEnabled
                        ? AppTheme.success
                        : AppTheme.textSecondary.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Continuous translate',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'Auto-translates each chapter when you tap Next',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _continuousEnabled,
                  onChanged: (val) async {
                    setState(() => _continuousEnabled = val);
                    await StorageService.instance.setContinuousEnabled(val);
                    if (val && _translatedText.isEmpty && !_translating) {
                      _startTranslation();
                    } else if (!val && _translating) {
                      _cancelTranslation();
                    }
                  },
                ),
              ],
            ),
          ),

          if (_translating)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              color: AppTheme.accentSoft.withValues(alpha: 0.35),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _chunkTotal == 0
                              ? 'Starting translation…'
                              : 'Translating chunk $_chunkCurrent of $_chunkTotal',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _chunkTotal == 0
                                ? null
                                : _chunkCurrent / _chunkTotal,
                            minHeight: 4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _cancelTranslation,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),

          if (showPlaceholder)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _startTranslation(force: true),
                  icon: const Icon(Icons.translate, size: 18),
                  label: const Text('Translate this chapter'),
                ),
              ),
            ),

          if (_busy)
            const LinearProgressIndicator(minHeight: 2),

          Expanded(
            child: showPlaceholder
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_stories_outlined,
                            size: 40,
                            color: AppTheme.textSecondary.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Translation will appear here',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 15,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Turn on Continuous translate or tap the button above.',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : SelectionArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Text(
                            _displayText,
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
          ),
        ],
      ),
      bottomNavigationBar: ReaderNavBar(
        hasPrev: _prevUrl != null,
        hasNext: _nextUrl != null,
        hasToc: _tocUrl != null,
        busy: _busy || _translating,
        onPrev: () {
          if (_prevUrl == null) {
            _showSnack('No previous-chapter link found on this page.');
            return;
          }
          _navigate(_prevUrl!);
        },
        onNext: () {
          if (_nextUrl == null) {
            _showSnack('No next-chapter link found on this page.');
            return;
          }
          _navigate(_nextUrl!);
        },
        onToc: _openToc,
      ),
    );
  }
}
