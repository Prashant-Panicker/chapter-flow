import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/browser_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppTheme.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  String? startupError;
  try {
    await StorageService.instance.init();
  } catch (error, stackTrace) {
    startupError = error.toString();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ChapterFlow startup',
        context: ErrorDescription('Storage initialization failed'),
      ),
    );
  }

  runApp(ChapterFlowApp(startupError: startupError));
}

class ChapterFlowApp extends StatelessWidget {
  const ChapterFlowApp({super.key, this.startupError});

  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ChapterFlow',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: RootShell(startupError: startupError),
    );
  }
}

/// Which root tab is showing. Exposed so a pushed screen can hand control
/// back to the Browser tab — the WebView only exists there, so anything
/// needing a live page has to go through it.
///
/// TODO: Consider scoping this to the RootShell widget tree (e.g., via
/// InheritedWidget or Provider) instead of module-level global to reduce
/// implicit coupling between screens.
final ValueNotifier<int> rootTabIndex = ValueNotifier<int>(0);

class RootShell extends StatefulWidget {
  const RootShell({super.key, this.startupError});

  final String? startupError;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int get _index => rootTabIndex.value;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _startupError = widget.startupError;
    rootTabIndex.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    rootTabIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_startupError != null) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 48, color: AppTheme.accent),
                const SizedBox(height: 12),
                Text(
                  'Storage initialization failed.',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.textPrimary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _startupError!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    String? retryError;
                    try {
                      await StorageService.instance.init();
                    } catch (error) {
                      retryError = error.toString();
                    }
                    if (!mounted) return;
                    setState(() => _startupError = retryError);
                    if (retryError != null) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Retry failed: $retryError')),
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _startupError = null),
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continue anyway'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          if (!StorageService.instance.isInitialized) const _StorageWarning(),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                const BrowserScreen(),
                Scaffold(
                  appBar: AppBar(title: const Text('Library')),
                  body: const LibraryScreen(),
                ),
                Scaffold(
                  appBar: AppBar(title: const Text('Settings')),
                  body: const SettingsScreen(),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => rootTabIndex.value = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: 'Browser',
          ),
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark_outlined),
            selectedIcon: Icon(Icons.collections_bookmark),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Shown after "Continue anyway": storage calls silently no-op, so the empty
/// library and unsaved settings need an explanation.
class _StorageWarning extends StatelessWidget {
  const _StorageWarning();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        color: AppTheme.danger.withValues(alpha: 0.18),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 18, color: AppTheme.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Storage is unavailable — chapters and settings will not be saved.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
