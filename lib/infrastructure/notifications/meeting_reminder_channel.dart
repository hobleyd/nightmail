import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/window_utils.dart';
import 'meeting_reminder_board.dart';

/// How the meeting-reminders window talks back to the main window, which owns
/// [MeetingReminderBoard].
///
/// The main window pushes rows to the window with
/// `WindowController.invokeMethod`; this is the other direction. The window
/// registers its own handler first and then pulls a [snapshot], so it is
/// current whichever of its start and a push lands first.
///
/// Registered [ChannelMode.unidirectional], like `ReminderReconcileChannel`:
/// the main window is the sole handler.
abstract final class MeetingReminderChannel {
  static const _channel = WindowMethodChannel(
    'au.com.sharpblue.nightmail/meeting_reminders',
    mode: ChannelMode.unidirectional,
  );

  /// The method the main window calls on the reminders window to replace its
  /// rows, and the one that asks it to close.
  static const setRowsMethod = 'setRows';
  static const closeMethod = 'close';

  static const _snapshotMethod = 'snapshot';
  static const _dismissMethod = 'dismiss';
  static const _silenceMethod = 'silence';

  /// Main window only.
  static Future<void> listen(MeetingReminderBoard board) async {
    if (!AppWindow.isMain) return;
    try {
      await _channel.setMethodCallHandler((MethodCall call) async {
        switch (call.method) {
          case _snapshotMethod:
            return [for (final r in board.rows) r.toJson()];
          case _dismissMethod:
            final id = call.arguments as String?;
            if (id != null) board.dismiss(id);
          case _silenceMethod:
            final key = call.arguments as String?;
            if (key != null) board.silence(key);
        }
        return null;
      });
    } catch (e) {
      debugPrint('MeetingReminderChannel.listen failed: $e');
    }
  }

  /// The main window's current rows, or null if it could not be asked.
  static Future<List<MeetingReminderRow>?> snapshot() async {
    try {
      return MeetingReminderRow.listFromJson(
        await _channel.invokeMethod<List<dynamic>>(_snapshotMethod),
      );
    } catch (e) {
      debugPrint('MeetingReminderChannel.snapshot failed: $e');
      return null;
    }
  }

  static Future<void> dismiss(String rowId) async {
    try {
      await _channel.invokeMethod<void>(_dismissMethod, rowId);
    } catch (e) {
      debugPrint('MeetingReminderChannel.dismiss failed: $e');
    }
  }

  static Future<void> silence(String meetingKey) async {
    try {
      await _channel.invokeMethod<void>(_silenceMethod, meetingKey);
    } catch (e) {
      debugPrint('MeetingReminderChannel.silence failed: $e');
    }
  }
}
