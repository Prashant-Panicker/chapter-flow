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
final ValueNotifier<int> rootTabIndex = ValueNotifier<int>(0);

class RootShell extends StatefulWidget {
  const RootShell({super.key, this.startupError});

  final String? startupError;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int get _index => rootTabIndex.value;

  @override
  void initState() {
    super.initState();
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
    if (widget.startupError != null) {
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
                  'ChapterFlow started with a storage warning.',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.textPrimary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.startupError!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final Widget body;
    switch (_index) {
      case 0:
        body = const BrowserScreen();
        break;
      case 1:
        body = Scaffold(
          appBar: AppBar(title: const Text('Library')),
          body: const LibraryScreen(),
        );
        break;
      default:
        body = Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: const SettingsScreen(),
        );
    }

    return Scaffold(
      body: body,
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
