import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/platform/window_utils.dart';
import '../../core/theme/app_colors.dart';
import '../../infrastructure/notifications/meeting_reminder_board.dart';
import '../../infrastructure/notifications/meeting_reminder_channel.dart';
import '../../injection_container.dart';
import '../pages/meeting_reminders_window.dart';
import 'meeting_reminder_list.dart';

/// Shows [MeetingReminderBoard]'s rows as the one meeting-reminders dialog:
/// its own window on macOS, Windows and Linux, a modal dialog over the app on
/// iOS and Android, where there are no sub-windows.
///
/// Mounted in the main window's home shell, which is the only place the board
/// is fed and ticks.
class MeetingReminderHost extends StatefulWidget {
  const MeetingReminderHost({super.key, required this.child});

  final Widget child;

  @override
  State<MeetingReminderHost> createState() => _MeetingReminderHostState();
}

class _MeetingReminderHostState extends State<MeetingReminderHost> {
  static final bool _usesWindow =
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  late final MeetingReminderBoard _board = sl<MeetingReminderBoard>();
  StreamSubscription<MeetingReminderUpdate>? _subscription;

  /// Window work runs one update at a time: creating the window is slow, and
  /// a second update finding no window yet would create another.
  Future<void> _windowWork = Future.value();
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _subscription = _board.updates.listen(_onUpdate);
    if (_usesWindow) unawaited(MeetingReminderChannel.listen(_board));
    unawaited(_board.start());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _onUpdate(MeetingReminderUpdate update) {
    if (_usesWindow) {
      _windowWork = _windowWork
          .then((_) => _presentInWindow(update))
          .catchError((Object e) {
        debugPrint('[MeetingReminders] window update failed: $e');
      });
    } else {
      _presentInDialog(update);
    }
  }

  Future<void> _presentInWindow(MeetingReminderUpdate update) async {
    final rows = [for (final r in update.rows) r.toJson()];
    final existing = await findSubWindow(meetingRemindersWindowType);
    if (existing != null) {
      try {
        await existing.invokeMethod<void>(
          rows.isEmpty
              ? MeetingReminderChannel.closeMethod
              : MeetingReminderChannel.setRowsMethod,
          rows,
        );
        if (update.alert && rows.isNotEmpty) await existing.show();
        return;
      } catch (_) {
        // Closed since the lookup — a new alert opens a fresh one below.
      }
    }
    if (!update.alert || rows.isEmpty) return;
    debugPrint('[MeetingReminders] opening for ${rows.length} meeting(s)');
    await createSubWindow(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': meetingRemindersWindowType,
          'rows': rows,
        }),
      ),
    );
  }

  void _presentInDialog(MeetingReminderUpdate update) {
    // An open dialog follows the board itself; only a new alert opens one.
    if (_dialogOpen || !update.alert || update.rows.isEmpty || !mounted) return;
    _dialogOpen = true;
    unawaited(showDialog<void>(
      context: context,
      builder: (_) => _MeetingReminderDialog(board: _board),
    ).whenComplete(() => _dialogOpen = false));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _MeetingReminderDialog extends StatefulWidget {
  const _MeetingReminderDialog({required this.board});

  final MeetingReminderBoard board;

  @override
  State<_MeetingReminderDialog> createState() => _MeetingReminderDialogState();
}

class _MeetingReminderDialogState extends State<_MeetingReminderDialog> {
  late List<MeetingReminderRow> _rows = widget.board.rows;
  StreamSubscription<MeetingReminderUpdate>? _subscription;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.board.updates.listen((update) {
      if (update.rows.isEmpty) {
        _pop();
      } else if (mounted) {
        setState(() => _rows = update.rows);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _pop() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.colors.surfacePanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 420),
        child: SingleChildScrollView(
          child: MeetingReminderList(
            rows: _rows,
            onDismiss: (row) => widget.board.silence(row.meetingKey),
            onDismissAll: () {
              for (final r in _rows) {
                widget.board.dismiss(r.id);
              }
              _pop();
            },
          ),
        ),
      ),
    );
  }
}
