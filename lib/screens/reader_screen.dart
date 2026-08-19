import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/chapter.dart';
import '../services/ai_provider.dart';
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
    this.bookTitle,
    this.chapterTitle,
    this.chapterNumber,
    this.prevUrl,
    this.nextUrl,
    this.tocUrl,
  });

  final String url;
  final String pageTitle;
  final String bodyText;
  final String? bookTitle;
  final String? chapterTitle;
  final String? chapterNumber;
  final String? prevUrl;
  final String? nextUrl;
  final String? tocUrl;
  final InAppWebViewController webViewController;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  static const _mobileChromeUA =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  late String _url;
  late String _pageTitle;
  late String _rawText;
  String _translatedText = '';
  String _sourceBookTitle = '';
  String? _englishBookTitle;
  String _sourceChapterTitle = '';
  String? _englishChapterTitle;
  String? _chapterNumber;
  String? _prevUrl;
  String? _nextUrl;
  String? _tocUrl;

  final ScrollController _scrollController = ScrollController();

  ReaderViewMode _viewMode = ReaderViewMode.english;
  bool _continuousEnabled = false;
  bool _busy = false;
  bool _translating = false;
  bool _cancelRequested = false;
  bool _prefetching = false;
  bool _prefetchCancelRequested = false;
  bool _appInBackground = false;
  bool _resumeTranslation = false;
  bool _prefetchHandoff = false;
  String? _prefetchUrl;
  Future<void>? _prefetchFuture;
  TranslationService? _activeTranslator;
  TranslationService? _prefetchTranslator;
  Completer<Map<String, dynamic>>? _prefetchExtractionCompleter;
  HeadlessInAppWebView? _prefetchWebView;
  Timer? _translationUiTimer;
  String? _pendingTranslatedText;
  int _pendingChunkCurrent = 0;
  int _pendingChunkTotal = 0;
  int _continuousChangeId = 0;
  int _chunkCurrent = 0;
  int _chunkTotal = 0;
  double _fontSize = StorageService.defaultFontSize;
  List<String> _completedParts = [];
  String _prefetchPartialText = '';
  int _prefetchChunkCurrent = 0;
  int _prefetchChunkTotal = 0;
  List<String> _prefetchCompletedParts = [];

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRequested = true;
    _prefetchCancelRequested = true;
    _activeTranslator?.cancel();
    _prefetchTranslator?.cancel();
    _prefetchWebView?.dispose();
    _translationUiTimer?.cancel();
    _persistProgress();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _url = widget.url;
    _pageTitle = widget.pageTitle;
    _rawText = widget.bodyText;
    _sourceBookTitle = _normalizeBookTitle(widget.bookTitle);
    _sourceChapterTitle = _normalizeChapterTitle(widget.chapterTitle);
    _chapterNumber = widget.chapterNumber?.trim().isEmpty ?? true
        ? null
        : widget.chapterNumber!.trim();
    _prevUrl = widget.prevUrl;
    _nextUrl = widget.nextUrl;
    _tocUrl = widget.tocUrl;
    _loadPrefsAndMaybeTranslate();
    _resolveEnglishTitles();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      _resumeAfterBackground();
      return;
    }
    _persistProgress();
    if (state == AppLifecycleState.detached) {
      _appInBackground = true;
      if (_translating && !_prefetchHandoff) {
        _resumeTranslation = true;
        _cancelRequested = true;
        _activeTranslator?.cancel();
      }
      if (_prefetching) {
        if (_prefetchHandoff) _resumeTranslation = true;
        _prefetchCancelRequested = true;
        _prefetchTranslator?.cancel();
      }
      final extraction = _prefetchExtractionCompleter;
      if (extraction != null && !extraction.isCompleted) {
        extraction.completeError(TranslationCancelledException());
      }
      _prefetchWebView?.dispose();
    }
  }

  void _resumeAfterBackground() {
    if (!mounted || _appInBackground) return;
    if (_resumeTranslation && !_translating) {
      _resumeTranslation = false;
      _startTranslation(force: true, keepCheckpoint: true);
      return;
    }
    if (_continuousEnabled &&
        _translatedText.isNotEmpty &&
        !_translating &&
        !_prefetching) {
      _prefetchFuture = _prefetchNextChapter();
    }
  }

  Future<void> _loadPrefsAndMaybeTranslate() async {
    final enabled = await StorageService.instance.getContinuousEnabled();
    final fontSize = await StorageService.instance.getFontSize();
    final cached = StorageService.instance.getChapter(_url);
    if (!mounted) return;
    setState(() {
      _continuousEnabled = enabled;
      _fontSize = fontSize;
      if (cached != null && cached.translatedText.isNotEmpty) {
        _translatedText = cached.translatedText;
        if (cached.completedSourceChunks > 0) {
          _completedParts = cached.translatedText
              .split('\n\n')
              .where((p) => p.trim().isNotEmpty)
              .toList();
          if (_completedParts.length > cached.completedSourceChunks) {
            _completedParts =
                _completedParts.take(cached.completedSourceChunks).toList();
          }
        }
      }
    });
    if (cached != null && cached.isFullyTranslated) {
      _restoreProgress(cached.scrollPosition);
    }
    if (_continuousEnabled &&
        (cached == null || !cached.isFullyTranslated)) {
      await _startTranslation(keepCheckpoint: true);
    } else if (_continuousEnabled) {
      _prefetchFuture = _prefetchNextChapter();
    }
  }

  Future<TranslationService?> _buildTranslator({
    bool showMissingKeyMessage = true,
  }) async {
    final provider = await StorageService.instance.getAiProvider();
    String? key;
    try {
      key = await StorageService.instance.getApiKeyFor(provider);
    } catch (_) {
      if (showMissingKeyMessage) _showSnack('API key unavailable.');
      return null;
    }
    if (key == null || key.isEmpty) {
      if (showMissingKeyMessage) {
        _showSnack(
          'Add your ${provider.displayName} API key in Settings to translate.',
        );
      }
      return null;
    }
    final gist = await StorageService.instance.getGistMode();
    return TranslationService(
      apiKey: key,
      provider: provider,
      mode: gist ? TranslationMode.gist : TranslationMode.full,
    );
  }

  // --- Temporary stubs; full implementations being restored ---
  Future<void> _startTranslation({bool force = false, bool keepCheckpoint = false}) async {
    final translator = await _buildTranslator();
    if (translator == null || !mounted) return;
    _activeTranslator = translator;
    setState(() {
      _translating = true;
      _cancelRequested = false;
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
      setState(() {
        _translatedText = result;
        _translating = false;
      });
      await _saveChapter();
    } on TranslationCancelledException {
      if (mounted) setState(() => _translating = false);
    } catch (e) {
      if (mounted) {
        setState(() => _translating = false);
        _showSnack('Translation error: $e');
      }
    } finally {
      if (identical(_activeTranslator, translator)) _activeTranslator = null;
    }
  }

  void _cancelTranslation() {
    setState(() => _cancelRequested = true);
    _activeTranslator?.cancel();
  }

  Future<void> _setContinuousEnabled(bool enabled) async {
    setState(() => _continuousEnabled = enabled);
    await StorageService.instance.setContinuousEnabled(enabled);
    if (enabled && _translatedText.isEmpty && !_translating) {
      _startTranslation();
    }
  }

  String _normalizeBookTitle(String? extracted) {
    final value = extracted?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return Uri.tryParse(_url)?.host ?? 'Unknown book';
  }

  String get _displayBookTitle =>
      (_englishBookTitle?.trim().isNotEmpty ?? false)
          ? _englishBookTitle!
          : _sourceBookTitle;

  String _normalizeChapterTitle(String? extracted) {
    final value = extracted?.trim() ?? '';
    return value.isNotEmpty ? value : _pageTitle.trim();
  }

  String get _displayChapterTitle {
    if (_englishChapterTitle?.trim().isNotEmpty ?? false) {
      return _englishChapterTitle!;
    }
    if (_chapterNumber?.trim().isNotEmpty ?? false) {
      return 'Chapter ${_chapterNumber!}';
    }
    return _sourceChapterTitle.isEmpty ? 'Chapter' : _sourceChapterTitle;
  }

  String get _seriesKey =>
      Chapter.seriesKeyFor(Uri.tryParse(_url)?.host ?? '', _sourceBookTitle);

  Future<void> _resolveEnglishTitles() async {
    final translator = await _buildTranslator(showMissingKeyMessage: false);
    if (translator == null) return;
    if (_sourceBookTitle.isNotEmpty && _englishBookTitle == null) {
      final english = await translator.translateTitle(_sourceBookTitle);
      if (mounted && english.isNotEmpty) {
        setState(() => _englishBookTitle = english);
      }
    }
    if (_sourceChapterTitle.isNotEmpty) {
      final english = await translator.translateTitle(_sourceChapterTitle);
      if (mounted && english.isNotEmpty) {
        setState(() => _englishChapterTitle = english);
      }
    }
  }

  Future<void> _saveChapter({int checkpointChunks = 0}) async {
    if (_translatedText.isEmpty) return;
    final uri = Uri.tryParse(_url);
    await StorageService.instance.saveChapter(
      Chapter(
        id: _url,
        url: _url,
        bookTitle: _sourceBookTitle,
        bookTitleEnglish: _englishBookTitle,
        chapterTitle:
            _sourceChapterTitle.isEmpty ? _pageTitle : _sourceChapterTitle,
        chapterTitleEnglish: _englishChapterTitle,
        chapterNumber: _chapterNumber,
        rawText: _rawText,
        translatedText: _translatedText,
        savedAt: DateTime.now(),
        lastReadAt: DateTime.now(),
        sourceDomain: uri?.host ?? '',
        prevUrl: _prevUrl,
        nextUrl: _nextUrl,
        tocUrl: _tocUrl,
        completedSourceChunks: checkpointChunks,
      ),
    );
  }

  Future<void> _prefetchNextChapter() async {
    // Prefetch restored in follow-up; continuous mode still translates current.
  }

  Future<void> _navigate(String targetUrl) async {
    _persistProgress();
    if (_translating) _cancelTranslation();
    setState(() => _busy = true);
    try {
      final previousUrl =
          (await widget.webViewController.getUrl())?.toString() ?? _url;
      await widget.webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetUrl)),
      );
      await _waitForLoadThenExtract(targetUrl, previousUrl: previousUrl);
    } catch (_) {
      _showSnack('Navigation failed.');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waitForLoadThenExtract(
    String targetUrl, {
    required String previousUrl,
  }) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      try {
        final currentUrl =
            (await widget.webViewController.getUrl())?.toString();
        final progress = await widget.webViewController.getProgress() ?? 0;
        if (currentUrl == null || currentUrl == previousUrl || progress < 80) {
          continue;
        }
        final raw = await widget.webViewController
            .evaluateJavascript(source: kExtractChapterJs);
        final data = parseExtractResult(raw);
        final bodyText = (data['bodyText'] as String? ?? '').trim();
        if (bodyText.length >= 40) {
          setState(() {
            _url = currentUrl;
            _pageTitle = data['pageTitle'] as String? ?? '';
            _rawText = bodyText;
            _prevUrl = data['prevUrl'] as String?;
            _nextUrl = data['nextUrl'] as String?;
            _tocUrl = data['tocUrl'] as String?;
            _sourceChapterTitle =
                _normalizeChapterTitle(data['chapterTitle'] as String?);
            _sourceBookTitle =
                _normalizeBookTitle(data['bookTitle'] as String?);
            _englishChapterTitle = null;
            _translatedText = '';
            _busy = false;
          });
          if (_continuousEnabled) await _startTranslation();
          return;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _busy = false);
      _showSnack('Chapter not found.');
    }
  }

  Future<void> _openToc() async {
    if (_tocUrl == null) {
      _showSnack('TOC unavailable.');
      return;
    }
    try {
      await widget.webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(_tocUrl!)),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      _showSnack('TOC failed to open.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _restoreProgress(double fraction) {
    if (fraction <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max <= 0) return;
      _scrollController.jumpTo((fraction * max).clamp(0, max));
    });
  }

  void _persistProgress() {
    if (_translating || !_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return;
    unawaited(
      StorageService.instance.saveReadingProgress(
        _url,
        (_scrollController.offset / max).clamp(0.0, 1.0),
      ),
    );
  }

  Future<void> _setFontSize(double size) async {
    final clamped = size.clamp(
      StorageService.minFontSize,
      StorageService.maxFontSize,
    );
    if (clamped == _fontSize) return;
    setState(() => _fontSize = clamped);
    await StorageService.instance.setFontSize(clamped);
  }

  String get _displayText {
    switch (_viewMode) {
      case ReaderViewMode.english:
        return _translatedText.isEmpty ? '' : _translatedText;
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _displayChapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              _displayBookTitle,
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
            onPressed: () => _setFontSize(_fontSize - 1),
            icon: const Icon(Icons.text_decrease, size: 20),
          ),
          IconButton(
            tooltip: 'Larger text',
            onPressed: () => _setFontSize(_fontSize + 1),
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
          if (_translating)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              color: AppTheme.accentSoft.withValues(alpha: 0.35),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _chunkTotal == 0
                          ? 'Translating…'
                          : 'Chunk $_chunkCurrent/$_chunkTotal',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
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
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: showPlaceholder
                ? const Center(
                    child: Text(
                      'No translation',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  )
                : SelectionArea(
                    child: SingleChildScrollView(
                      controller: _scrollController,
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
        autoTranslateEnabled: _continuousEnabled,
        autoTranslateBusy: false,
        onAutoTranslateChanged: _setContinuousEnabled,
        busy: _busy || _translating,
        onPrev: () {
          if (_prevUrl != null) _navigate(_prevUrl!);
        },
        onNext: () {
          if (_nextUrl != null) _navigate(_nextUrl!);
        },
        onToc: _openToc,
      ),
    );
  }
}
