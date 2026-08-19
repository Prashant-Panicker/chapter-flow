part of 'reader_screen.dart';

  Future<void> _navigate(String targetUrl) async {
    // Captures where you were before _url moves on to the new chapter.
    _persistProgress();
    if (_translating && !_prefetchHandoff) _cancelTranslation();

    final isPrefetchTarget =
        _prefetching && _prefetchUrl != null && _prefetchUrl == targetUrl;

    if (_prefetching && !isPrefetchTarget) {
      _prefetchCancelRequested = true;
      _prefetchTranslator?.cancel();
      final extraction = _prefetchExtractionCompleter;
      if (extraction != null && !extraction.isCompleted) {
        extraction.completeError(TranslationCancelledException());
      }
      await _prefetchWebView?.dispose();
    }

    if (isPrefetchTarget) {
      // Keep the in-flight job; UI will attach to its stream.
      _prefetchHandoff = true;
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

          final handingOff = _prefetchHandoff &&
              (_prefetchUrl == targetUrl || _prefetchUrl == resolvedUrl);

          setState(() {
            _url = resolvedUrl;
            _pageTitle = data['pageTitle'] as String? ?? '';
            _rawText = bodyText;
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
            if (handingOff) {
              // Attach live prefetch stream instead of clearing.
              _translatedText = _prefetchPartialText;
              _completedParts = List.from(_prefetchCompletedParts);
              _chunkCurrent = _prefetchChunkCurrent;
              _chunkTotal = _prefetchChunkTotal;
              _translating = true;
              _busy = false;
            } else {
              _translatedText = '';
              _completedParts = [];
            }
          });
          _scrollToTop();
          unawaited(_resolveEnglishTitles());

          if (handingOff) {
            // Stream continues via prefetch onProgress → UI.
            // When prefetch finishes it will clear _translating.
            return;
          }

          var cached = StorageService.instance.getChapter(resolvedUrl);
          if ((cached == null || !cached.isFullyTranslated) &&
              (_prefetchUrl == targetUrl || _prefetchUrl == resolvedUrl)) {
            await _prefetchFuture;
            cached = StorageService.instance.getChapter(resolvedUrl) ??
                StorageService.instance.getChapter(targetUrl);
          }
          if (!mounted) return;
          if (cached != null && cached.isFullyTranslated) {
            await StorageService.instance.touchLastRead(cached.url);
            if (!mounted) return;
            setState(() {
              _translatedText = cached!.translatedText;
              _englishChapterTitle ??= cached.chapterTitleEnglish;
              _englishBookTitle ??= cached.bookTitleEnglish;
              _completedParts = [];
              _busy = false;
            });
            _restoreProgress(cached.scrollPosition);
            await _pruneCurrentSeries();
            if (!mounted) return;
            if (_continuousEnabled) {
              _prefetchFuture = _prefetchNextChapter();
            }
          } else if (cached != null &&
              cached.completedSourceChunks > 0 &&
              cached.translatedText.isNotEmpty) {
            // Resume a partial checkpoint for this chapter.
            _completedParts = cached.translatedText
                .split('\n\n')
                .where((p) => p.trim().isNotEmpty)
                .take(cached.completedSourceChunks)
                .toList();
            setState(() {
              _translatedText = _completedParts.join('\n\n');
              _busy = false;
            });
            if (_continuousEnabled) {
              await _startTranslation(keepCheckpoint: true);
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

  /// Drops you back where you stopped reading a chapter you have already
  /// seen. A freshly prefetched chapter has no saved position, so it lands
  /// at the top like any other new chapter.
  void _restoreProgress(double fraction) {
    if (fraction <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max <= 0) return;
      _scrollController.jumpTo((fraction * max).clamp(0, max));
    });
  }

  /// Skipped while a translation is streaming in, because the text is still
  /// growing and any fraction measured against it would be meaningless.
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
