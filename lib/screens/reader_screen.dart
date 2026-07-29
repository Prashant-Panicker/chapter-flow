import 'dart:async';

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
  double _fontSize = 17;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRequested = true;
    _prefetchCancelRequested = true;
    _activeTranslator?.cancel();
    _prefetchTranslator?.cancel();
    _prefetchWebView?.dispose();
    _translationUiTimer?.cancel();
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

    if (state == AppLifecycleState.detached) {
      _appInBackground = true;
      if (_translating) {
        _resumeTranslation = true;
        _cancelRequested = true;
        _activeTranslator?.cancel();
      }
      _prefetchCancelRequested = true;
      _prefetchTranslator?.cancel();
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
      _startTranslation(force: true);
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
    } else if (_continuousEnabled) {
      _prefetchFuture = _prefetchNextChapter();
    }
  }

  Future<TranslationService?> _buildTranslator({
    bool showMissingKeyMessage = true,
  }) async {
    String? key;
    try {
      key = await StorageService.instance.getApiKey();
    } catch (_) {
      if (showMissingKeyMessage) _showSnack('API key unavailable.');
      return null;
    }
    if (key == null || key.isEmpty) {
      if (showMissingKeyMessage) {
        _showSnack('Add your Moonshot API key in Settings to translate.');
      }
      return null;
    }
    return TranslationService(apiKey: key);
  }

  Future<void> _startTranslation({bool force = false}) async {
    if (_translating) return;
    if (!force && _translatedText.isNotEmpty) return;
    if (_appInBackground) {
      _resumeTranslation = true;
      return;
    }

    final translator = await _buildTranslator();
    if (translator == null || !mounted) return;
    if (_appInBackground) {
      _resumeTranslation = true;
      return;
    }
    _activeTranslator = translator;
    _translationUiTimer?.cancel();
    _pendingTranslatedText = null;

    setState(() {
      _translating = true;
      _cancelRequested = false;
      _chunkCurrent = 0;
      _chunkTotal = 0;
      if (force) _translatedText = '';
    });

    var retryRequested = false;
    try {
      // Runs alongside the first chunk instead of before it, so pinning terms
      // costs no perceived delay. Chunk 1 uses whatever the series already
      // knows; later chunks pick up anything new this chapter introduced.
      unawaited(_buildGlossary(translator, _rawText, _seriesKey));
      final result = await translator.translateChapter(
        rawText: _rawText,
        glossary: () => StorageService.instance.glossaryFor(_seriesKey),
        shouldCancel: () => _cancelRequested,
        onProgress: (current, total, partial) {
          _queueTranslationProgress(current, total, partial);
        },
      );
      if (!mounted) return;
      _translationUiTimer?.cancel();
      _pendingTranslatedText = null;
      setState(() => _translatedText = result);
      await _saveChapter();
      if (_continuousEnabled) {
        _prefetchFuture = _prefetchNextChapter();
      }
    } on TranslationCancelledException {
      if (!_appInBackground && !_resumeTranslation) {
        _showSnack('Translation stopped.');
      }
    } on TranslationChunkFailure catch (e) {
      if (!mounted) return;
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
        retryRequested = true;
      }
    } catch (e) {
      _showSnack('Translation error: $e');
    } finally {
      if (mounted) {
        setState(() => _translating = false);
        _resumeAfterBackground();
      }
      if (identical(_activeTranslator, translator)) {
        _activeTranslator = null;
      }
    }
    if (retryRequested && mounted) {
      await _startTranslation(force: true);
    }
  }

  void _queueTranslationProgress(int current, int total, String partial) {
    if (!mounted) return;
    _pendingChunkCurrent = current;
    _pendingChunkTotal = total;
    _pendingTranslatedText = partial;
    if (_translationUiTimer?.isActive ?? false) return;

    _translationUiTimer = Timer(
      const Duration(milliseconds: 100),
      _flushTranslationProgress,
    );
  }

  void _flushTranslationProgress() {
    final partial = _pendingTranslatedText;
    if (!mounted || partial == null) return;
    _pendingTranslatedText = null;
    setState(() {
      _chunkCurrent = _pendingChunkCurrent;
      _chunkTotal = _pendingChunkTotal;
      _translatedText = partial;
    });
  }

  void _cancelTranslation() {
    setState(() => _cancelRequested = true);
    _activeTranslator?.cancel();
  }

  Future<void> _setContinuousEnabled(bool enabled) async {
    final changeId = ++_continuousChangeId;
    setState(() => _continuousEnabled = enabled);
    if (!enabled) {
      _prefetchCancelRequested = true;
      _prefetchTranslator?.cancel();
      final extraction = _prefetchExtractionCompleter;
      if (extraction != null && !extraction.isCompleted) {
        extraction.completeError(TranslationCancelledException());
      }
      _prefetchWebView?.dispose();
      if (_translating) _cancelTranslation();
    }
    try {
      await StorageService.instance.setContinuousEnabled(enabled);
    } catch (_) {
      if (mounted && changeId == _continuousChangeId) {
        setState(() => _continuousEnabled = !enabled);
        _showSnack('Setting not saved.');
      }
      return;
    }
    if (!mounted || changeId != _continuousChangeId) return;
    if (enabled && _translatedText.isEmpty && !_translating) {
      _startTranslation();
    } else if (enabled && !_prefetching) {
      _prefetchFuture = _prefetchNextChapter();
    }
  }

  /// Uses the novel name the page exposed; falls back to a page-title
  /// heuristic when the site gives us nothing usable.
  String _normalizeBookTitle(String? extracted) {
    final value = extracted?.trim() ?? '';
    if (value.isNotEmpty) return value;
    final parts = _pageTitle.split(RegExp(r'\s*[-–_|]\s*'));
    if (parts.length >= 2 && parts.first.trim().length > 1) {
      return parts.first.trim();
    }
    return Uri.tryParse(_url)?.host ?? 'Unknown book';
  }

  String get _displayBookTitle {
    final english = _englishBookTitle?.trim();
    if (english != null && english.isNotEmpty) return english;
    return _sourceBookTitle;
  }

  /// Uses the page's chapter heading; falls back to the page title so the
  /// reader always has something to show.
  String _normalizeChapterTitle(String? extracted) {
    final value = extracted?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return _pageTitle.trim();
  }

  /// Never shows a source-language heading when an English form exists.
  String get _displayChapterTitle {
    final english = _englishChapterTitle?.trim();
    if (english != null && english.isNotEmpty) return english;
    final number = _chapterNumber?.trim();
    if (number != null && number.isNotEmpty) return 'Chapter $number';
    return _sourceChapterTitle.isEmpty ? 'Chapter' : _sourceChapterTitle;
  }

  String get _seriesKey =>
      Chapter.seriesKeyFor(Uri.tryParse(_url)?.host ?? '', _sourceBookTitle);

  /// Translates the novel name and chapter heading so every surface reads in
  /// English. Both are short, cached requests and failures are non-fatal.
  Future<void> _resolveEnglishTitles() async {
    final bookSource = _sourceBookTitle;
    final chapterSource = _sourceChapterTitle;
    if (bookSource.isEmpty && chapterSource.isEmpty) return;

    final translator = await _buildTranslator(showMissingKeyMessage: false);
    if (translator == null) return;

    if (bookSource.isNotEmpty && _englishBookTitle == null) {
      final english = await translator.translateTitle(bookSource);
      if (!mounted) return;
      if (english.isNotEmpty && _sourceBookTitle == bookSource) {
        setState(() => _englishBookTitle = english);
        await StorageService.instance.setSeriesEnglishTitle(
          _seriesKey,
          english,
        );
      }
    }

    if (!mounted || chapterSource.isEmpty) return;
    final chapterUrl = _url;
    final english = await translator.translateTitle(chapterSource);
    if (!mounted) return;
    if (english.isNotEmpty && _sourceChapterTitle == chapterSource) {
      setState(() => _englishChapterTitle = english);
      await StorageService.instance.setChapterEnglishTitle(
        chapterUrl,
        english,
      );
    }
  }

  /// Best-effort term pinning. Runs off the translation queue and swallows
  /// every failure: a missing glossary must never stop a chapter rendering.
  Future<void> _buildGlossary(
    TranslationService translator,
    String rawText,
    String seriesKey, {
    bool prefetch = false,
  }) async {
    if (_sourceBookTitle.isEmpty || rawText.isEmpty) return;
    try {
      final found = await translator.extractGlossary(
        rawText: rawText,
        known: StorageService.instance.glossaryFor(seriesKey),
        shouldCancel: () =>
            prefetch ? _prefetchCancelRequested : _cancelRequested,
      );
      if (found.isEmpty) return;
      await StorageService.instance.mergeGlossary(seriesKey, found);
    } catch (_) {
      // Ignored on purpose.
    }
  }

  /// Keeps at most the chapter being read plus the prefetched next one, so
  /// the library only ever surfaces the last read chapter of this novel.
  Future<void> _pruneCurrentSeries() async {
    if (_sourceBookTitle.isEmpty) return;
    await StorageService.instance.pruneSeries(
      _seriesKey,
      keepIds: {_url, if (_nextUrl != null) _nextUrl!},
    );
  }

  Future<void> _saveChapter() async {
    if (_translatedText.isEmpty) return;
    final uri = Uri.tryParse(_url);
    final chapter = Chapter(
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
    );
    await StorageService.instance.saveChapter(chapter);
    await _pruneCurrentSeries();
  }

  Future<void> _prefetchNextChapter() async {
    final nextUrl = _nextUrl;
    if (_prefetching || nextUrl == null || nextUrl == _url) return;
    final cached = StorageService.instance.getChapter(nextUrl);
    if (cached != null && cached.translatedText.isNotEmpty) return;

    final translator = await _buildTranslator(showMissingKeyMessage: false);
    if (translator == null ||
        !mounted ||
        !_continuousEnabled ||
        _appInBackground) {
      return;
    }
    _prefetchTranslator = translator;

    setState(() {
      _prefetching = true;
      _prefetchCancelRequested = false;
      _prefetchUrl = nextUrl;
    });

    try {
      final data = await _extractInBackground(nextUrl);
      if (_prefetchCancelRequested || !_continuousEnabled) return;

      final rawText = (data['bodyText'] as String? ?? '').trim();
      final seriesKey = _seriesKey;
      // The next chapter's terms are pinned while it is still being
      // prefetched, so by the time the reader gets there the wording is
      // already settled.
      unawaited(
        _buildGlossary(translator, rawText, seriesKey, prefetch: true),
      );
      final translatedText = await translator.translateChapter(
        rawText: rawText,
        glossary: () => StorageService.instance.glossaryFor(seriesKey),
        shouldCancel: () => _prefetchCancelRequested || !_continuousEnabled,
        onProgress: (_, __, ___) {},
      );
      if (_prefetchCancelRequested || !_continuousEnabled) return;

      final pageTitle = data['pageTitle'] as String? ?? '';
      final uri = Uri.tryParse(nextUrl);
      final nextBookTitle = (data['bookTitle'] as String? ?? '').trim().isEmpty
          ? _sourceBookTitle
          : (data['bookTitle'] as String).trim();
      final nextChapterNumber = (data['chapterNumber'] as String? ?? '').trim();
      final nextChapterTitle = (data['chapterTitle'] as String? ?? '').trim();
      final nextChapterTitleEnglish = nextChapterTitle.isEmpty
          ? ''
          : await translator.translateTitle(nextChapterTitle);
      await StorageService.instance.saveChapter(
        Chapter(
          id: nextUrl,
          url: nextUrl,
          bookTitle: nextBookTitle,
          bookTitleEnglish:
              nextBookTitle == _sourceBookTitle ? _englishBookTitle : null,
          chapterTitle:
              nextChapterTitle.isEmpty ? pageTitle : nextChapterTitle,
          chapterTitleEnglish: nextChapterTitleEnglish.isEmpty
              ? null
              : nextChapterTitleEnglish,
          chapterNumber:
              nextChapterNumber.isEmpty ? null : nextChapterNumber,
          rawText: rawText,
          translatedText: translatedText,
          savedAt: DateTime.now(),
          // Not read yet — keep it out of the library until the user lands
          // on it, so the library keeps showing the last read chapter.
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(0),
          sourceDomain: uri?.host ?? '',
          prevUrl: data['prevUrl'] as String?,
          nextUrl: data['nextUrl'] as String?,
          tocUrl: data['tocUrl'] as String?,
        ),
      );
      await _pruneCurrentSeries();
    } on TranslationCancelledException {
      // Expected when continuous translation is disabled or the reader closes.
    } catch (e) {
      if (mounted && !_prefetchCancelRequested) {
        _showSnack('Next chapter not ready.');
      }
    } finally {
      await _prefetchWebView?.dispose();
      _prefetchWebView = null;
      _prefetchExtractionCompleter = null;
      if (identical(_prefetchTranslator, translator)) {
        _prefetchTranslator = null;
      }
      if (mounted) {
        setState(() {
          _prefetching = false;
          _prefetchUrl = null;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _extractInBackground(String url) async {
    final completer = Completer<Map<String, dynamic>>();
    _prefetchExtractionCompleter = completer;
    var extracting = false;

    _prefetchWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        userAgent: _mobileChromeUA,
        javaScriptEnabled: true,
        cacheEnabled: true,
        databaseEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      onLoadStop: (controller, _) async {
        if (extracting || completer.isCompleted) return;
        extracting = true;
        try {
          for (var attempt = 0; attempt < 15; attempt++) {
            if (_prefetchCancelRequested) {
              throw TranslationCancelledException();
            }
            final raw = await controller.evaluateJavascript(
              source: kExtractChapterJs,
            );
            final data = parseExtractResult(raw);
            if ((data['bodyText'] as String? ?? '').trim().length >= 40) {
              completer.complete(data);
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          throw StateError('Next chapter text did not appear');
        } catch (e, stackTrace) {
          if (!completer.isCompleted) completer.completeError(e, stackTrace);
        }
      },
      onReceivedError: (_, request, error) {
        if ((request.isForMainFrame ?? false) && !completer.isCompleted) {
          completer.completeError(
            StateError('Failed to load next chapter: ${error.description}'),
          );
        }
      },
    );
    await _prefetchWebView!.run();
    return completer.future.timeout(const Duration(seconds: 30));
  }

  Future<void> _navigate(String targetUrl) async {
    if (_translating) _cancelTranslation();
    if (_prefetching && _prefetchUrl != targetUrl) {
      _prefetchCancelRequested = true;
      _prefetchTranslator?.cancel();
      final extraction = _prefetchExtractionCompleter;
      if (extraction != null && !extraction.isCompleted) {
        extraction.completeError(TranslationCancelledException());
      }
      await _prefetchWebView?.dispose();
    }
    setState(() => _busy = true);
    try {
      final previousUrl =
          (await widget.webViewController.getUrl())?.toString() ?? _url;
      await widget.webViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(targetUrl)),
      );
      await _waitForLoadThenExtract(targetUrl, previousUrl: previousUrl);
    } catch (e) {
      _showSnack('Navigation failed.');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waitForLoadThenExtract(
    String targetUrl, {
    required String previousUrl,
  }) async {
    const maxAttempts = 25;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      try {
        final currentUrl =
            (await widget.webViewController.getUrl())?.toString();
        final progress = await widget.webViewController.getProgress() ?? 0;
        if (currentUrl == null ||
            _samePage(currentUrl, previousUrl) ||
            progress < 80) {
          continue;
        }
        final raw = await widget.webViewController
            .evaluateJavascript(source: kExtractChapterJs);
        final data = parseExtractResult(raw);
        final bodyText = (data['bodyText'] as String? ?? '').trim();
        if (bodyText.length >= 40 && bodyText != _rawText.trim()) {
          final resolvedUrl = currentUrl;
          await StorageService.instance.setLastUrl(resolvedUrl);
          if (!mounted) return;
          final extractedBookTitle = data['bookTitle'] as String?;
          final extractedChapterTitle = data['chapterTitle'] as String?;
          final extractedChapterNumber =
              (data['chapterNumber'] as String? ?? '').trim();
          setState(() {
            _url = resolvedUrl;
            _pageTitle = data['pageTitle'] as String? ?? '';
            _rawText = bodyText;
            _translatedText = '';
            _prevUrl = data['prevUrl'] as String?;
            _nextUrl = data['nextUrl'] as String?;
            _tocUrl = data['tocUrl'] as String?;
            _chapterNumber =
                extractedChapterNumber.isEmpty ? null : extractedChapterNumber;
            _sourceChapterTitle = _normalizeChapterTitle(extractedChapterTitle);
            _englishChapterTitle = null;
            final nextBookTitle = _normalizeBookTitle(extractedBookTitle);
            if (nextBookTitle != _sourceBookTitle) {
              _sourceBookTitle = nextBookTitle;
              _englishBookTitle = null;
            }
          });
          _scrollToTop();
          unawaited(_resolveEnglishTitles());
          var cached = StorageService.instance.getChapter(resolvedUrl);
          if ((cached == null || cached.translatedText.isEmpty) &&
              (_prefetchUrl == targetUrl || _prefetchUrl == resolvedUrl)) {
            await _prefetchFuture;
            cached = StorageService.instance.getChapter(resolvedUrl) ??
                StorageService.instance.getChapter(targetUrl);
          }
          if (!mounted) return;
          if (cached != null && cached.translatedText.isNotEmpty) {
            await StorageService.instance.touchLastRead(cached.url);
            if (!mounted) return;
            setState(() {
              _translatedText = cached!.translatedText;
              _englishChapterTitle ??= cached.chapterTitleEnglish;
              _englishBookTitle ??= cached.bookTitleEnglish;
              _busy = false;
            });
            _scrollToTop();
            await _pruneCurrentSeries();
            if (!mounted) return;
            if (_continuousEnabled) {
              _prefetchFuture = _prefetchNextChapter();
            }
          } else if (_continuousEnabled) {
            await _startTranslation();
            if (mounted) setState(() => _busy = false);
          } else {
            setState(() => _busy = false);
          }
          return;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _busy = false);
      _showSnack(
        'Chapter not found.',
      );
    }
  }

  bool _samePage(String first, String second) {
    Uri? normalize(String value) {
      final uri = Uri.tryParse(value);
      if (uri == null) return null;
      final path = uri.path.length > 1 && uri.path.endsWith('/')
          ? uri.path.substring(0, uri.path.length - 1)
          : uri.path;
      return uri.replace(path: path, fragment: '');
    }

    return normalize(first) == normalize(second);
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
      if (!mounted) return;
      Navigator.of(context).pop();
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

  /// New chapters always start at the top, including cached ones where the
  /// scroll view is reused instead of rebuilt.
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(0);
    });
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
                              ? 'Starting…'
                              : 'Chunk $_chunkCurrent/$_chunkTotal',
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
                            'No translation',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 15,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
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
        autoTranslateBusy: _prefetching,
        onAutoTranslateChanged: (enabled) {
          _setContinuousEnabled(enabled);
        },
        busy: _busy || _translating,
        onPrev: () {
          if (_prevUrl == null) {
            _showSnack('No previous chapter.');
            return;
          }
          _navigate(_prevUrl!);
        },
        onNext: () {
          if (_nextUrl == null) {
            _showSnack('No next chapter.');
            return;
          }
          _navigate(_nextUrl!);
        },
        onToc: _openToc,
      ),
    );
  }
}
