import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// App-owned navigation chrome — always visible in Reader.
class ReaderNavBar extends StatelessWidget {
  const ReaderNavBar({
    super.key,
    required this.hasPrev,
    required this.hasNext,
    required this.hasToc,
    required this.onPrev,
    required this.onNext,
    required this.onToc,
    required this.autoTranslateEnabled,
    required this.autoTranslateBusy,
    required this.onAutoTranslateChanged,
    this.busy = false,
  });

  final bool hasPrev;
  final bool hasNext;
  final bool hasToc;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToc;
  final bool autoTranslateEnabled;
  final bool autoTranslateBusy;
  final ValueChanged<bool> onAutoTranslateChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showLabels = constraints.maxWidth >= 360;
        return Material(
          color: AppTheme.surface,
          elevation: 0,
          child: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.border)),
              ),
              child: Row(
                children: [
              Expanded(
                child: _ToggleButton(
                  enabled: autoTranslateEnabled,
                  busy: autoTranslateBusy,
                  onChanged: onAutoTranslateChanged,
                  showLabel: showLabels,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NavButton(
                  icon: Icons.chevron_left_rounded,
                  label: 'Prev',
                  showLabel: showLabels,
                  enabled: hasPrev && !busy,
                  onTap: onPrev,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NavButton(
                  icon: Icons.list_alt_rounded,
                  label: 'TOC',
                  showLabel: showLabels,
                  enabled: hasToc && !busy,
                  onTap: onToc,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _NavButton(
                  icon: Icons.chevron_right_rounded,
                  label: 'Next',
                  showLabel: showLabels,
                  enabled: hasNext && !busy,
                  onTap: onNext,
                  emphasized: hasNext && !busy,
                  iconTrailing: true,
                ),
              ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.enabled,
    required this.busy,
    required this.onChanged,
    required this.showLabel,
  });

  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? AppTheme.accent : AppTheme.textPrimary;

    return Tooltip(
      message: enabled ? 'Turn auto-translate off' : 'Turn auto-translate on',
      child: Material(
        color: enabled ? AppTheme.accentSoft : AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => onChanged(!enabled),
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                    ),
                  )
                else
                  Icon(Icons.translate_rounded, size: 18, color: foreground),
                if (showLabel) ...[
                  const SizedBox(width: 4),
                  Text(
                    enabled ? 'Auto on' : 'Auto off',
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.label,
    required this.showLabel,
    required this.enabled,
    required this.onTap,
    this.iconTrailing = false,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final bool showLabel;
  final bool enabled;
  final VoidCallback onTap;
  final bool iconTrailing;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final bg = !enabled
        ? AppTheme.surfaceAlt.withValues(alpha: 0.4)
        : emphasized
            ? AppTheme.accentSoft
            : AppTheme.surfaceAlt;
    final fg = !enabled
        ? AppTheme.textSecondary.withValues(alpha: 0.45)
        : emphasized
            ? AppTheme.accent
            : AppTheme.textPrimary;

    return Tooltip(
      message: label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!iconTrailing || !showLabel)
                  Icon(icon, size: 22, color: fg),
                if (showLabel && !iconTrailing) const SizedBox(width: 2),
                if (showLabel)
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                if (showLabel && iconTrailing) const SizedBox(width: 2),
                if (showLabel && iconTrailing)
                  Icon(icon, size: 22, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
