import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_colors.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';

class ReminderPopupWindowApp extends StatelessWidget {
  const ReminderPopupWindowApp({super.key, required this.arguments});

  final Map<String, dynamic> arguments;

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
    ),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    final eventTitle =
        arguments['eventTitle'] as String? ?? 'Upcoming event';
    final startIso = arguments['startIso'] as String?;
    final startTime =
        startIso != null ? DateTime.tryParse(startIso)?.toLocal() : null;
    // Which alert of the event's reminder series opened this popup — the
    // lead-time one, or the final one at the start. Absent for a reminder
    // scheduled before the series existed.
    final minutesUntilStart = arguments['minutesUntilStart'] as int?;

    return BlocProvider<ThemeCubit>(
      create: (_) => ThemeCubit()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: _ReminderPopupPage(
              eventTitle: eventTitle,
              startTime: startTime,
              minutesUntilStart: minutesUntilStart,
            ),
          );
        },
      ),
    );
  }
}

class _ReminderPopupPage extends StatelessWidget {
  const _ReminderPopupPage({
    required this.eventTitle,
    this.startTime,
    this.minutesUntilStart,
  });

  final String eventTitle;
  final DateTime? startTime;
  final int? minutesUntilStart;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final timeLabel = startTime != null
        ? DateFormat('h:mm a').format(startTime!)
        : null;
    final dateLabel = startTime != null
        ? DateFormat('EEE, MMM d').format(startTime!)
        : null;
    final countdownLabel = switch (minutesUntilStart) {
      null => null,
      <= 0 => 'Starting now',
      1 => 'Starting in 1 minute',
      final m when m < 60 => 'Starting in $m minutes',
      final m => 'Starting in ${m ~/ 60} hour${m ~/ 60 == 1 ? '' : 's'}',
    };

    return Scaffold(
      backgroundColor: c.surfacePanel,
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.event_rounded,
                    color: AppColors.accent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Event Reminder',
                        style: TextStyle(
                          color: c.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        eventTitle,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (timeLabel != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.access_time_rounded,
                      size: 13, color: c.textMuted),
                  const SizedBox(width: 5),
                  Text(
                    '$dateLabel · $timeLabel',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ],
            if (countdownLabel != null) ...[
              const SizedBox(height: 6),
              Text(
                countdownLabel,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const Spacer(),
            FilledButton(
              onPressed: () => windowManager.close(),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                padding: const EdgeInsets.symmetric(vertical: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Dismiss', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}
