import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/extraction_js.dart';
import '../services/js_result.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'reader_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _controller;
  final TextEditingController _addressController = TextEditingController();
  String _currentUrl = 'about:blank';
  bool _loading = false;
  bool _extracting = false;
  double _progress = 0;
  bool _startUrlReady = false;
  String _startUrl = 'about:blank';
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// Main-frame load failure for the navigation in flight. Held back until
  /// the page settles, because a bad status often still renders a usable
  /// page (bot checks) or is immediately superseded by a redirect.
  String? _pendingError;

  static const _mobileChromeUA =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    _restoreLastUrl();
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _restoreLastUrl() async {
    final last = await StorageService.instance.getLastUrl();
    if (!mounted) return;
    setState(() {
      _startUrl = last ?? 'about:blank';
      _currentUrl = _startUrl;
      _addressController.text =
          _startUrl == 'about:blank' ? '' : _startUrl;
      _startUrlReady = true;
    });
  }

  Future<void> _updateNav() async {
    final c = _controller;
    if (c == null) return;
    final back = await c.canGoBack();
    final forward = await c.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  Future<void> _go(String input) async {
    var url = input.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.contains('.') && !url.contains(' ')) {
        url = 'https://$url';
      } else {
        url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
      }
    }
    try {
      await _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (_) {
      _showSnack('Could not open address.');
    }
  }

  Future<void> _enterReader() async {
    final controller = _controller;
    if (controller == null || _loading) return;
    setState(() => _extracting = true);
    try {
      final extractionUrl = (await controller.getUrl())?.toString();
      if (extractionUrl == null) return;
      final raw = await controller.evaluateJavascript(source: kExtractChapterJs);
      final currentUrl = (await controller.getUrl())?.toString();
      if (currentUrl != extractionUrl) {
        _showSnack('Page changed. Try again.');
        return;
      }
      final data = parseExtractResult(raw);
      final bodyText = (data['bodyText'] as String? ?? '').trim();

      if (bodyText.length < 40) {
        _showSnack(
          'No chapter text found.',
        );
        return;
      }

      await StorageService.instance.setLastUrl(extractionUrl);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(
            url: extractionUrl,
            pageTitle: data['pageTitle'] as String? ?? '',
            bodyText: bodyText,
            bookTitle: data['bookTitle'] as String?,
            chapterTitle: data['chapterTitle'] as String?,
            chapterNumber: data['chapterNumber'] as String?,
            prevUrl: data['prevUrl'] as String?,
            nextUrl: data['nextUrl'] as String?,
            tocUrl: data['tocUrl'] as String?,
            webViewController: controller,
          ),
        ),
      );
    } catch (e) {
      _showSnack('Could not open reader.');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  void _showSnack(String message, {bool withRetry = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      // Without this, a multi-hop navigation queues several snackbars and
      // they keep reappearing long after the page has recovered.
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: Duration(seconds: withRetry ? 6 : 4),
          action: withRetry
              ? SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _controller?.reload(),
                )
              : null,
        ),
      );
  }

  /// Decides whether the failure recorded during this navigation is worth
  /// telling the user about, now that the page has finished loading.
  Future<void> _resolvePendingError(InAppWebViewController controller) async {
    final message = _pendingError;
    _pendingError = null;
    if (message == null || !mounted) return;

    try {
      final state = parseExtractResult(
        await controller.evaluateJavascript(source: kPageStateJs),
      );
      // A bot check is a working page the user has to complete, not an error.
      if (state['challenge'] == true) return;
      // The status was bad but the site rendered real content anyway.
      if (((state['textLength'] as num?) ?? 0) >= 400) return;
    } catch (_) {
      // Probe failed, so the page really is unusable — fall through.
    }

    if (!mounted) return;
    _showSnack(message, withRetry: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        titleSpacing: 8,
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            color: AppTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _addressController,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13.5,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Novel site URL',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    filled: false,
                  ),
                  textInputAction: TextInputAction.go,
                  keyboardType: TextInputType.url,
                  onSubmitted: _go,
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _addressController,
                builder: (context, value, _) => SizedBox(
                  width: 32,
                  height: 32,
                  child: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear address',
                          onPressed: _addressController.clear,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 17,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                ),
              ),
              InkWell(
                onTap: () => _go(_addressController.text),
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.arrow_forward_rounded,
                      size: 18, color: AppTheme.accent),
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Back',
            icon: Icon(
              Icons.arrow_back_ios_new,
              size: 16,
              color: _canGoBack ? AppTheme.textPrimary : AppTheme.textSecondary.withValues(alpha: 0.35),
            ),
            onPressed: _canGoBack
                ? () async {
                    await _controller?.goBack();
                    await _updateNav();
                  }
                : null,
          ),
          IconButton(
            tooltip: 'Forward',
            icon: Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: _canGoForward ? AppTheme.textPrimary : AppTheme.textSecondary.withValues(alpha: 0.35),
            ),
            onPressed: _canGoForward
                ? () async {
                    await _controller?.goForward();
                    await _updateNav();
                  }
                : null,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: _loading ? 2 : 0,
            child: LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              minHeight: 2,
              backgroundColor: AppTheme.surface,
            ),
          ),
          Expanded(
            child: !_startUrlReady
                ? const Center(child: CircularProgressIndicator())
                : InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(_startUrl)),
                    initialSettings: InAppWebViewSettings(
                      userAgent: _mobileChromeUA,
                      javaScriptEnabled: true,
                      javaScriptCanOpenWindowsAutomatically: false,
                      cacheEnabled: true,
                      cacheMode: CacheMode.LOAD_DEFAULT,
                      databaseEnabled: true,
                      domStorageEnabled: true,
                      hardwareAcceleration: true,
                      mixedContentMode:
                          MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
                      thirdPartyCookiesEnabled: true,
                      supportZoom: true,
                      mediaPlaybackRequiresUserGesture: true,
                      allowFileAccessFromFileURLs: false,
                      allowUniversalAccessFromFileURLs: false,
                      geolocationEnabled: false,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                    },
                    onLoadStart: (controller, url) {
                      if (!mounted) return;
                      _pendingError = null;
                      ScaffoldMessenger.of(context).removeCurrentSnackBar();
                      setState(() {
                        _loading = true;
                        if (url != null) {
                          _currentUrl = url.toString();
                          _addressController.text = _currentUrl;
                        }
                      });
                    },
                    onProgressChanged: (controller, progress) {
                      if (!mounted) return;
                      setState(() => _progress = progress / 100);
                    },
                    onLoadStop: (controller, url) async {
                      if (!mounted) return;
                      setState(() {
                        _loading = false;
                        if (url != null) {
                          _currentUrl = url.toString();
                          _addressController.text = _currentUrl;
                        }
                      });
                      await StorageService.instance.setLastUrl(_currentUrl);
                      await _updateNav();
                      await _resolvePendingError(controller);
                    },
                    onUpdateVisitedHistory: (controller, url, isReload) {
                      if (!mounted) return;
                      if (url != null) {
                        setState(() {
                          _currentUrl = url.toString();
                          _addressController.text = _currentUrl;
                        });
                        StorageService.instance.setLastUrl(_currentUrl);
                      }
                      _updateNav();
                    },
                    onReceivedError: (controller, request, error) {
                      if (!mounted) return;
                      if (!(request.isForMainFrame ?? false)) return;
                      // A cancelled load is normal during redirect chains.
                      if (error.type
                          .toString()
                          .toUpperCase()
                          .contains('CANCEL')) {
                        return;
                      }
                      setState(() => _loading = false);
                      _pendingError = 'Page failed to load.';
                    },
                    onReceivedHttpError: (controller, request, response) {
                      if (!mounted) return;
                      final code = response.statusCode ?? 0;
                      if (!(request.isForMainFrame ?? false) || code < 400) {
                        return;
                      }
                      setState(() => _loading = false);
                      _pendingError = 'Page error ($code).';
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _extracting || _loading ? null : _enterReader,
        icon: _extracting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF0B0D12),
                ),
              )
            : const Icon(Icons.menu_book_rounded),
        label: Text(
          _extracting ? 'Extracting…' : 'Enter Reader',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
