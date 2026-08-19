import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/chapter.dart';
import '../models/glossary_entry.dart';
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
  int _translationAttemptId = 0; // Per-attempt token to prevent state races
  bool _cancelRequested = false;
  bool _resumeTranslation = false;
  TranslationService? _activeTranslator;
  int _chunkCurrent = 0;
  int _chunkTotal = 0;
  double _fontSize = StorageService.defaultFontSize;
  List<String> _completedParts = [];
  int _checkpointChunks = 0; // Chunk count backing _completedParts, for resume
  List<GlossaryEntry> _glossary = []; // Extracted glossary for this series
  bool _glossaryReady = false; // True once this chapter's terms were extracted
  List<GlossaryEntry> _pendingGlossary = []; // Extracted, not yet persisted

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRequested = true;
    _activeTranslator?.cancel();
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
      _resumeAfterBackground();
      return;
    }
    _persistProgress();
    // `inactive` fires for transient events (app switcher, control centre,
    // permission dialogs); only paused/detached mean the app left the foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_translating) {
        _resumeTranslation = true;
        _cancelRequested = true;
        _activeTranslator?.cancel();
      }
    }
  }

  void _resumeAfterBackground() {
    if (!mounted) return;
    if (_resumeTranslation && !_translating) {
      _resumeTranslation = false;
      _startTranslation(force: true, keepCheckpoint: true);
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
        // Only resume from an exact per-chunk checkpoint; re-splitting the
        // joined text on '\n\n' can't recover the original chunk boundaries.
        if (cached.completedSourceChunks > 0 &&
            cached.checkpointParts != null &&
            cached.checkpointParts!.isNotEmpty) {
          _checkpointChunks = cached.completedSourceChunks;
          _completedParts = List<String>.from(cached.checkpointParts!);
        }
      }
    });
    if (cached != null && cached.isFullyTranslated) {
      _restoreProgress(cached.scrollPosition);
    }
    if (_continuousEnabled &&
        (cached == null || !cached.isFullyTranslated)) {
      await _startTranslation(keepCheckpoint: true);
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

  Future<void> _startTranslation({
    bool force = false,
    bool keepCheckpoint = false,
  }) async {
    final translator = await _buildTranslator();
    if (translator == null || !mounted) return;

    // Increment attempt ID to prevent state races from stale attempts
    _translationAttemptId++;
    final attemptId = _translationAttemptId;

    _activeTranslator = translator;
    setState(() {
      _translating = true;
      _cancelRequested = false;
    });

    final resumeChunks = keepCheckpoint ? _checkpointChunks : 0;
    final resumeParts = keepCheckpoint ? _completedParts : const <String>[];
    DateTime? lastCheckpointWrite;

    try {
      final seriesKey = Chapter.seriesKeyFor(
        Uri.tryParse(_url)?.host ?? '',
        _sourceBookTitle,
      );

      // Resuming mid-chapter reuses the terms the first attempt extracted;
      // re-running extraction would pay for the same request twice.
      if (!_glossaryReady || resumeChunks == 0) {
        _glossary = StorageService.instance.glossaryFor(seriesKey).toList();
        _pendingGlossary = [];
        if (!_cancelRequested) {
          final extracted = await translator.extractGlossary(
            rawText: _rawText,
            known: _glossary,
            shouldCancel: () =>
                _cancelRequested || _translationAttemptId != attemptId,
          );
          if (extracted.isNotEmpty &&
              !_cancelRequested &&
              _translationAttemptId == attemptId) {
            _glossary.addAll(extracted);
            _pendingGlossary = extracted;
          }
        }
        _glossaryReady = true;
      }

      // Translate the chapter with glossary context, resuming from any checkpoint
      final result = await translator.translateChapter(
        rawText: _rawText,
        glossary: () => _glossary,
        shouldCancel: () => _cancelRequested || _translationAttemptId != attemptId,
        startFromChunk: resumeChunks,
        priorParts: resumeParts,
        onProgress: (current, total, partial) {
          if (!mounted || _translationAttemptId != attemptId) return;
          setState(() {
            _chunkCurrent = current;
            _chunkTotal = total;
            _translatedText = partial;
          });
        },
        onChunkComplete: (completed, total, parts) {
          if (_translationAttemptId != attemptId) return;
          _checkpointChunks = completed;
          _completedParts = List<String>.from(parts);
          // The imminent final save below covers the last chunk; avoid a
          // redundant double write to Hive.
          if (completed == total) return;
          // Throttle checkpoint writes so long chapters don't hit Hive every chunk.
          final now = DateTime.now();
          if (lastCheckpointWrite != null &&
              now.difference(lastCheckpointWrite!) < const Duration(seconds: 5)) {
            return;
          }
          lastCheckpointWrite = now;
          unawaited(
            _saveChapter(
              checkpointChunks: completed,
              checkpointParts: _completedParts,
            ),
          );
        },
      );

      // Verify this attempt is still current before updating state
      if (_translationAttemptId != attemptId || !mounted) return;

      setState(() {
        _translatedText = result;
        _translating = false;
      });

      // Translation finished: clear the checkpoint and save the final text
      _checkpointChunks = 0;
      _completedParts = [];
      await _saveChapter(checkpointChunks: 0);
      if (_pendingGlossary.isNotEmpty) {
        // Note: returns false if glossary hit capacity; for now we ignore this
        // signal and rely on first-write-wins to preserve consistency.
        // TODO: Consider showing a warning if glossary becomes full.
        await StorageService.instance.mergeGlossary(
          seriesKey,
          _pendingGlossary,
        );
        _pendingGlossary = [];
      }
    } on TranslationCancelledException {
      if (_translationAttemptId != attemptId) return;
      if (mounted) setState(() => _translating = false);
      await _flushCheckpoint();
    } catch (e) {
      if (mounted && _translationAttemptId == attemptId) {
        setState(() => _translating = false);
        _showSnack('Translation error: ${_sanitizeError(e)}');
      }
    } finally {
      if (identical(_activeTranslator, translator)) _activeTranslator = null;
    }
  }

  String _sanitizeError(dynamic error) {
    if (error is DioException) {
      return 'Network error. Check your connection and API key.';
    }
    return error.toString();
  }

  /// Persists the chunks that finished before a cancellation, so a process
  /// kill while backgrounded doesn't make the user pay for them again.
  Future<void> _flushCheckpoint() async {
    if (_checkpointChunks <= 0 || _completedParts.isEmpty) return;
    _translatedText = _completedParts.join('\n\n');
    await _saveChapter(
      checkpointChunks: _checkpointChunks,
      checkpointParts: _completedParts,
    );
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

  Future<void> _saveChapter({
    int checkpointChunks = 0,
    List<String>? checkpointParts,
  }) async {
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
        checkpointParts: checkpointChunks > 0 ? checkpointParts : null,
      ),
    );
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
            // A new chapter has nothing in common with the last one's
            // checkpoint or glossary — discard both.
            _checkpointChunks = 0;
            _completedParts = [];
            _glossary = [];
            _glossaryReady = false;
            _pendingGlossary = [];
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
