import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/ai_provider.dart';
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
  bool _gistMode = false;
  AiProvider _provider = AiProvider.kimi;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final provider = await StorageService.instance.getAiProvider();
    final key = await StorageService.instance.getApiKeyFor(provider);
    final gist = await StorageService.instance.getGistMode();
    if (!mounted) return;
    setState(() {
      _provider = provider;
      _hasKey = key != null && key.isNotEmpty;
      _savedKey = key ?? '';
      _controller.text = key ?? '';
      _gistMode = gist;
    });
  }

  Future<void> _switchProvider(AiProvider next) async {
    if (next == _provider) return;
    await StorageService.instance.setAiProvider(next);
    final key = await StorageService.instance.getApiKeyFor(next);
    if (!mounted) return;
    setState(() {
      _provider = next;
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
      await TranslationService(
        apiKey: value,
        provider: _provider,
      ).validateApiKey();
      await StorageService.instance.setApiKeyFor(_provider, value);
      if (!mounted) return;
      setState(() {
        _hasKey = true;
        _savedKey = value;
      });
      _showSnack('API key saved for ${_provider.displayName}.');
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
      await StorageService.instance.clearApiKeyFor(_provider);
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

  Future<void> _setGistMode(bool value) async {
    setState(() => _gistMode = value);
    await StorageService.instance.setGistMode(value);
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

  String get _keyHint {
    switch (_provider) {
      case AiProvider.kimi:
        return 'sk-… (Moonshot)';
      case AiProvider.deepseekV4Flash:
        return 'sk-… (DeepSeek)';
    }
  }

  String get _providerHelp {
    switch (_provider) {
      case AiProvider.kimi:
        return 'Get a key at platform.moonshot.cn. Model: kimi-k2.6.';
      case AiProvider.deepseekV4Flash:
        return 'Get a key at platform.deepseek.com. Model: deepseek-v4-flash.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final showingSavedKey =
        _hasKey && _controller.text.trim() == _savedKey;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _sectionCard(
          title: 'AI model',
          children: [
            const Text(
              'Switch between providers. Each keeps its own API key.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            SegmentedButton<AiProvider>(
              segments: const [
                ButtonSegment(
                  value: AiProvider.kimi,
                  label: Text('Kimi'),
                  icon: Icon(Icons.auto_awesome, size: 16),
                ),
                ButtonSegment(
                  value: AiProvider.deepseekV4Flash,
                  label: Text('DeepSeek V4 Flash'),
                  icon: Icon(Icons.bolt, size: 16),
                ),
              ],
              selected: {_provider},
              onSelectionChanged: (set) {
                if (set.isNotEmpty) _switchProvider(set.first);
              },
            ),
            const SizedBox(height: 8),
            Text(
              _providerHelp,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _sectionCard(
          title: '${_provider.displayName} API key',
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
                hintText: _keyHint,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
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
          title: 'Translation style',
          children: [
            const Text(
              'Condensed (gist) keeps events, dialogue, and context while '
              'cutting filler. New translations only — already-saved chapters '
              'are unchanged.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Condensed (gist) mode',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              ),
              subtitle: Text(
                _gistMode
                    ? 'On — shorter narrative output'
                    : 'Off — full translation',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              value: _gistMode,
              onChanged: _setGistMode,
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
