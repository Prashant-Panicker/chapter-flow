import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/storage_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _hasKey = false;
  bool _saving = false;
  String _savedKey = '';

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    final key = await StorageService.instance.getApiKey();
    if (!mounted) return;
    setState(() {
      _hasKey = key != null && key.isNotEmpty;
      _savedKey = key ?? '';
      _controller.text = key ?? '';
    });
  }

  Future<void> _saveKey() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      _showSnack('Enter a key first.');
      return;
    }
    setState(() => _saving = true);
    try {
      await TranslationService(apiKey: value).validateApiKey();
      await StorageService.instance.setApiKey(value);
      if (!mounted) return;
      setState(() {
        _hasKey = true;
        _savedKey = value;
      });
      _showSnack('API key saved.');
    } on ApiKeyValidationException catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not save key.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearKey() async {
    try {
      await StorageService.instance.clearApiKey();
      if (!mounted) return;
      setState(() {
        _hasKey = false;
        _savedKey = '';
        _controller.clear();
      });
      _showSnack('API key removed.');
    } catch (_) {
      _showSnack('Could not remove key.');
    }
  }

  Future<void> _clearWebViewData() async {
    try {
      await InAppWebViewController.clearAllCache();
      final cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
      _showSnack('Browser data cleared.');
    } catch (e) {
      _showSnack('Could not clear browser data.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _sectionCard({required String title, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showingSavedKey =
        _hasKey && _controller.text.trim() == _savedKey;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _sectionCard(
          title: 'Moonshot (Kimi) API key',
          children: [
            const Text(
              'Encrypted on this device.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'sk-…',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    color: AppTheme.textSecondary,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _saving ? null : _saveKey,
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF0B0D12),
                          ),
                        )
                      : const Text('Verify & save'),
                ),
                if (_hasKey)
                  OutlinedButton(
                    onPressed: _saving ? null : _clearKey,
                    child: const Text('Clear'),
                  ),
                if (showingSavedKey)
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 16, color: AppTheme.success),
                      SizedBox(width: 4),
                      Text(
                        'Saved',
                        style: TextStyle(color: AppTheme.success, fontSize: 12),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _sectionCard(
          title: 'Browser data',
          children: [
            const Text(
              'Clears browser cookies and cache.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _clearWebViewData,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: const Text('Clear cache & cookies'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _sectionCard(
          title: 'About',
          children: const [
            Text(
              'ChapterFlow 0.2.1',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}
