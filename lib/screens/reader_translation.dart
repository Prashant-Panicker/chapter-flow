part of 'reader_screen.dart';

  Future<void> _startTranslation({
    bool force = false,
    bool keepCheckpoint = false,
  }) async {
    if (_translating) return;
    if (!force && _translatedText.isNotEmpty && _completedParts.isEmpty) {
      // Fully translated already.
      final cached = StorageService.instance.getChapter(_url);
      if (cached != null && cached.isFullyTranslated) return;
    }
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

    if (force && !keepCheckpoint) {
      _completedParts = [];
    }

    final startFrom = _completedParts.length;
    final priorJoined =
        _completedParts.isEmpty ? '' : _completedParts.join('\n\n');

    setState(() {
      _translating = true;
      _cancelRequested = false;
      _chunkCurrent = startFrom;
      _chunkTotal = 0;
      if (force && !keepCheckpoint) {
        _translatedText = '';
      } else if (priorJoined.isNotEmpty) {
        _translatedText = priorJoined;
      }
    });

    var retryRequested = false;
    try {
      // Runs alongside the first remaining chunk so pinning costs no delay.
      unawaited(_buildGlossary(translator, _rawText, _seriesKey));
      final result = await translator.translateChapter(
        rawText: _rawText,
        glossary: () => StorageService.instance.glossaryFor(_seriesKey),
        shouldCancel: () => _cancelRequested,
        startFromChunk: startFrom,
        priorParts: List<String>.from(_completedParts),
        onChunkComplete: (completed, total, partial) {
          _completedParts = partial
              .split('\n\n')
              .where((p) => p.trim().isNotEmpty)
              .toList();
          // Keep list length aligned with completed count.
          if (_completedParts.length > completed) {
            _completedParts = _completedParts.take(completed).toList();
          }
          _translatedText = partial;
          unawaited(_saveChapter(checkpointChunks: completed));
        },
        onProgress: (current, total, partial) {
          _queueTranslationProgress(current, total, partial);
        },
      );
      if (!mounted) return;
      _translationUiTimer?.cancel();
      _pendingTranslatedText = null;
      _completedParts = [];
      setState(() => _translatedText = result);
      await _saveChapter(checkpointChunks: 0);
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
      await _startTranslation(force: true, keepCheckpoint: true);
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
    if (_prefetchHandoff) {
      _prefetchCancelRequested = true;
      _prefetchTranslator?.cancel();
    }
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

  /// Keeps a three-chapter window — the previous chapter, the one being
  /// read, and the prefetched next one — so stepping back to re-read the end
  /// of the last chapter never costs a re-translation.
  Future<void> _pruneCurrentSeries() async {
    if (_sourceBookTitle.isEmpty) return;
    await StorageService.instance.pruneSeries(
      _seriesKey,
      keepIds: {
        _url,
        if (_prevUrl != null) _prevUrl!,
        if (_nextUrl != null) _nextUrl!,
      },
    );
  }

  /// [checkpointChunks] > 0 marks an in-progress save; 0 means fully done.
  Future<void> _saveChapter({int checkpointChunks = 0}) async {
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
      completedSourceChunks: checkpointChunks,
    );
    await StorageService.instance.saveChapter(chapter);
    await _pruneCurrentSeries();
  }

