import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'APPEARANCE',
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 12),
              _ThemeSetting(),
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                  ),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeSetting extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ThemeCubit, ThemeState>(
      builder: (context, state) {
        return Row(
          children: [
            Text(
              'Theme',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: c.surfaceBase,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.separatorStrong),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<AppThemeMode>(
                  value: state.mode,
                  isDense: true,
                  dropdownColor: c.surfacePanel,
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                  items: const [
                    DropdownMenuItem(
                      value: AppThemeMode.system,
                      child: Text('OS Default'),
                    ),
                    DropdownMenuItem(
                      value: AppThemeMode.light,
                      child: Text('Light'),
                    ),
                    DropdownMenuItem(
                      value: AppThemeMode.dark,
                      child: Text('Dark'),
                    ),
                  ],
                  onChanged: (mode) {
                    if (mode != null) context.read<ThemeCubit>().setMode(mode);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
