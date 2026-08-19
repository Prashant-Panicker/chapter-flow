part of 'reader_screen.dart';

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
                  onPressed: _busy
                      ? null
                      : () => _startTranslation(force: true),
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
                            color: AppTheme.textSecondary
                                .withValues(alpha: 0.5),
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
        autoTranslateBusy: _prefetching && !_prefetchHandoff,
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
