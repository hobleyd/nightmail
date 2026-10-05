import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/platform/window_utils.dart';
import '../../core/theme/app_colors.dart';
import '../blocs/tasks/overdue_tasks_cubit.dart';

/// The Calendar, Tasks, AI and Commitments buttons, as a row.
///
/// Drawn at the foot of the folder panel everywhere, and on a phone also at
/// the foot of the email list — which is where the app now opens, so the
/// views have to be reachable without first backing out to the folders.
/// One widget so the two feet cannot drift apart.
///
/// On desktop a double-click brings up Calendar, Tasks or Commitments in its
/// own window — the one already open if there is one, see
/// [showOrCreateSubWindow] — and leaves the pane as it was. AI has no window
/// of its own.
class ViewShortcutButtons extends StatelessWidget {
  const ViewShortcutButtons({
    super.key,
    required this.onCalendarTapped,
    required this.onTasksTapped,
    required this.onAiTapped,
    required this.onCommitmentsTapped,
  });

  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
  final VoidCallback onAiTapped;
  final VoidCallback onCommitmentsTapped;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Red dot on the Tasks icon: the active account has something already past
    // due, in any of its lists — not only the one the pane last showed.
    final overdueTasks = context.watch<OverdueTasksCubit>().state;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ViewButton(
          icon: Icon(Icons.calendar_month_outlined,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'Calendar',
          onTap: onCalendarTapped,
          windowType: 'calendar',
        ),
        _ViewButton(
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
          onTap: onTasksTapped,
          windowType: 'tasks',
        ),
        _ViewButton(
          icon: Icon(Icons.auto_awesome_rounded,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'AI',
          onTap: onAiTapped,
        ),
        _ViewButton(
          // A screen-sized window where the pane becomes a four-column board.
          icon: Icon(Icons.handshake_outlined,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'Commitments',
          onTap: onCommitmentsTapped,
          windowType: 'commitments',
        ),
      ],
    );
  }
}

/// One of the four buttons.
///
/// A click toggles the pane; on desktop a double-click on a button with a
/// [windowType] opens that window instead. The two have to be told apart by
/// waiting: a click only toggles once the double-click interval has passed
/// with no second click, or the first half of every double-click would flip
/// the pane before the window appeared.
///
/// The wait is the OS's interval ([platformDoubleClickInterval]), not a
/// [GestureDetector.onDoubleTap]. That recognizer gives up after 300 ms where
/// macOS by default allows 500, so an ordinary double-click reached the old
/// wrapper as two single taps — the pane toggled twice and no window came.
///
/// A button without a window acts on the first click and ignores a second
/// inside the interval, so a double-click on it is one toggle, not two.
class _ViewButton extends StatefulWidget {
  const _ViewButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.windowType,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  /// The `type` the sub-window is created with, or null for a view that has
  /// no window of its own.
  final String? windowType;

  @override
  State<_ViewButton> createState() => _ViewButtonState();
}

class _ViewButtonState extends State<_ViewButton> {
  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Fetched once the button is on screen so a press never has to wait on
  /// the channel; Flutter's figure stands in until the answer lands.
  Duration _interval = kDoubleTapTimeout;

  /// Runs while a click is waiting to find out whether it was the first half
  /// of a double-click.
  Timer? _pending;

  /// When the last click on a windowless button landed.
  DateTime? _lastTap;

  bool get _opensWindow => widget.windowType != null && !_isMobile;

  @override
  void initState() {
    super.initState();
    platformDoubleClickInterval().then((d) {
      if (mounted) _interval = d;
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  void _pressed() {
    if (!_opensWindow) {
      final now = DateTime.now();
      final last = _lastTap;
      _lastTap = now;
      if (last != null && now.difference(last) < _interval) return;
      widget.onTap();
      return;
    }

    final pending = _pending;
    if (pending != null) {
      pending.cancel();
      _pending = null;
      unawaited(showOrCreateSubWindow(widget.windowType!));
      return;
    }

    _pending = Timer(_interval, () {
      _pending = null;
      // The callback is read now, not when the click landed: the pane state
      // it closes over may have been rebuilt in the meantime.
      if (mounted) widget.onTap();
    });
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: widget.icon,
      tooltip: widget.tooltip,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(
        minWidth: touchTarget(28),
        minHeight: touchTarget(28),
      ),
      onPressed: _pressed,
    );
  }
}
