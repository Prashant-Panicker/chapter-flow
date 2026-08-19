part of 'reader_screen.dart';

  Future<void> _prefetchNextChapter() async {
    final nextUrl = _nextUrl;
    if (_prefetching || nextUrl == null || nextUrl == _url) return;
    final cached = StorageService.instance.getChapter(nextUrl);
    if (cached != null && cached.isFullyTranslated) return;

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
      _prefetchHandoff = false;
      _prefetchUrl = nextUrl;
      _prefetchPartialText = '';
      _prefetchChunkCurrent = 0;
      _prefetchChunkTotal = 0;
      _prefetchCompletedParts = [];
    });

    try {
      final data = await _extractInBackground(nextUrl);
      if (_prefetchCancelRequested || !_continuousEnabled) return;

      final rawText = (data['bodyText'] as String? ?? '').trim();
      final seriesKey = _seriesKey;
      // Resume from any partial checkpoint already on disk for this URL.
      final existing = StorageService.instance.getChapter(nextUrl);
      var startFrom = 0;
      var priorParts = <String>[];
      if (existing != null &&
          existing.completedSourceChunks > 0 &&
          existing.translatedText.isNotEmpty) {
        startFrom = existing.completedSourceChunks;
        priorParts = existing.translatedText
            .split('\n\n')
            .where((p) => p.trim().isNotEmpty)
            .take(startFrom)
            .toList();
        _prefetchPartialText = priorParts.join('\n\n');
        _prefetchCompletedParts = List.from(priorParts);
      }

      unawaited(
        _buildGlossary(translator, rawText, seriesKey, prefetch: true),
      );
      final translatedText = await translator.translateChapter(
        rawText: rawText,
        glossary: () => StorageService.instance.glossaryFor(seriesKey),
        shouldCancel: () =>
            _prefetchCancelRequested ||
            (!_continuousEnabled && !_prefetchHandoff),
        startFromChunk: startFrom,
        priorParts: priorParts,
        onChunkComplete: (completed, total, partial) {
          _prefetchCompletedParts = partial
              .split('\n\n')
              .where((p) => p.trim().isNotEmpty)
              .take(completed)
              .toList();
          _prefetchPartialText = partial;
          // Persist checkpoint under the next chapter URL.
          unawaited(() async {
            final uri = Uri.tryParse(nextUrl);
            final pageTitle = data['pageTitle'] as String? ?? '';
            final nextBookTitle =
                (data['bookTitle'] as String? ?? '').trim().isEmpty
                    ? _sourceBookTitle
                    : (data['bookTitle'] as String).trim();
            final nextChapterNumber =
                (data['chapterNumber'] as String? ?? '').trim();
            final nextChapterTitle =
                (data['chapterTitle'] as String? ?? '').trim();
            await StorageService.instance.saveChapter(
              Chapter(
                id: nextUrl,
                url: nextUrl,
                bookTitle: nextBookTitle,
                bookTitleEnglish: nextBookTitle == _sourceBookTitle
                    ? _englishBookTitle
                    : null,
                chapterTitle:
                    nextChapterTitle.isEmpty ? pageTitle : nextChapterTitle,
                chapterNumber:
                    nextChapterNumber.isEmpty ? null : nextChapterNumber,
                rawText: rawText,
                translatedText: partial,
                savedAt: DateTime.now(),
                lastReadAt: DateTime.fromMillisecondsSinceEpoch(0),
                sourceDomain: uri?.host ?? '',
                prevUrl: data['prevUrl'] as String?,
                nextUrl: data['nextUrl'] as String?,
                tocUrl: data['tocUrl'] as String?,
                completedSourceChunks: completed,
              ),
            );
          }());
        },
        onProgress: (current, total, partial) {
          _prefetchChunkCurrent = current;
          _prefetchChunkTotal = total;
          _prefetchPartialText = partial;
          // If the user already navigated here, stream into the reader UI.
          if (_prefetchHandoff && _url == nextUrl && mounted) {
            _queueTranslationProgress(current, total, partial);
          }
        },
      );
      if (_prefetchCancelRequested && !_prefetchHandoff) return;

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
          lastReadAt: _prefetchHandoff
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(0),
          sourceDomain: uri?.host ?? '',
          prevUrl: data['prevUrl'] as String?,
          nextUrl: data['nextUrl'] as String?,
          tocUrl: data['tocUrl'] as String?,
          completedSourceChunks: 0,
        ),
      );
      await _pruneCurrentSeries();

      if (_prefetchHandoff && mounted && _url == nextUrl) {
        _completedParts = [];
        setState(() {
          _translatedText = translatedText;
          _translating = false;
          _prefetchHandoff = false;
        });
        if (_continuousEnabled) {
          _prefetchFuture = _prefetchNextChapter();
        }
      }
    } on TranslationCancelledException {
      // Expected when continuous translation is disabled or the reader closes.
    } catch (e) {
      if (mounted && !_prefetchCancelRequested) {
        _showSnack('Next chapter not ready.');
      }
      if (_prefetchHandoff && mounted) {
        setState(() {
          _translating = false;
          _prefetchHandoff = false;
        });
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
          if (!_prefetchHandoff) _prefetchUrl = null;
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

