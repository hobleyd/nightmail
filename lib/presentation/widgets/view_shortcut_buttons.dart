import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/platform/window_utils.dart';
import '../../core/theme/app_colors.dart';
import '../blocs/tasks/overdue_tasks_cubit.dart';

/// The Calendar, Tasks and AI buttons, as a row.
///
/// Drawn at the foot of the folder panel everywhere, and on a phone also at
/// the foot of the email list — which is where the app now opens, so the
/// three views have to be reachable without first backing out to the folders.
/// One widget so the two feet cannot drift apart.
///
/// On desktop a double-tap opens Calendar or Tasks in its own window.
class ViewShortcutButtons extends StatelessWidget {
  const ViewShortcutButtons({
    super.key,
    required this.onCalendarTapped,
    required this.onTasksTapped,
    required this.onAiTapped,
  });

  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
  final VoidCallback onAiTapped;

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Red dot on the Tasks icon: the active account has something already past
    // due, in any of its lists — not only the one the pane last showed.
    final overdueTasks = context.watch<OverdueTasksCubit>().state;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onDoubleTap: _isMobile
              ? null
              : () => createSubWindow(
                    WindowConfiguration(
                      arguments: jsonEncode({'type': 'calendar'}),
                    ),
                  ),
          child: IconButton(
            icon: Icon(Icons.calendar_month_outlined,
                size: touchIcon(16), color: c.textMuted),
            tooltip: 'Calendar',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: touchTarget(28),
              minHeight: touchTarget(28),
            ),
            onPressed: onCalendarTapped,
          ),
        ),
        GestureDetector(
          onDoubleTap: _isMobile
              ? null
              : () => createSubWindow(
                    WindowConfiguration(
                      arguments: jsonEncode({'type': 'tasks'}),
                    ),
                  ),
          child: IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.checklist_rounded,
                    size: touchIcon(16), color: c.textMuted),
                if (overdueTasks > 0)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.notification,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip:
                overdueTasks > 0 ? 'Tasks ($overdueTasks overdue)' : 'Tasks',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: touchTarget(28),
              minHeight: touchTarget(28),
            ),
            onPressed: onTasksTapped,
          ),
        ),
        IconButton(
          icon: Icon(Icons.auto_awesome_rounded,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'AI',
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
            minWidth: touchTarget(28),
            minHeight: touchTarget(28),
          ),
          onPressed: onAiTapped,
        ),
      ],
    );
  }
}
