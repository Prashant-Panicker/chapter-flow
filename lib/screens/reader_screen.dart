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

part 'reader_translation.dart';
part 'reader_prefetch.dart';
part 'reader_navigation.dart';
part 'reader_ui.dart';


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
  /// True while the active reader is displaying an in-flight prefetch stream.
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

  /// Fully finished chunk English for the chapter currently being translated.
  /// Used to resume without re-sending completed chunks.
  List<String> _completedParts = [];

  /// Live prefetch progress (shared so handoff can paint immediately).
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

    // Leaving the app may be the last chance to record where you were.
    _persistProgress();

    if (state == AppLifecycleState.detached) {
      _appInBackground = true;
      if (_translating && !_prefetchHandoff) {
        _resumeTranslation = true;
        _cancelRequested = true;
        _activeTranslator?.cancel();
      }
      // Prefetch (and handoff) also stop; checkpoint is already on disk.
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
      // Keep checkpoint so only remaining chunks are sent.
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
          // Prefer the stored count when it matches split length.
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
