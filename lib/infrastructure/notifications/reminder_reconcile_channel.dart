import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/window_utils.dart';

/// Lets a sub-window ask the main window to reconcile reminders now.
///
/// A sub-window cannot hand a reminder to the OS itself — see the note on
/// `NotificationService._plugin`. Without this nudge, a reminder created or
/// cancelled in the Calendar, Tasks or Event-Edit window would not reach the OS
/// until the main window's next periodic cycle up to 15 minutes later, which is
/// long enough to miss an imminent meeting's reminder outright (the trigger
/// having passed by then, it is dropped as stale) or to let a just-cancelled
/// meeting's reminder still fire.
///
/// Registered [ChannelMode.unidirectional]: the main window is the sole handler
/// and every sub-window may invoke it. This is the app's only cross-window
/// channel — sub-windows are otherwise fully autonomous, each with its own
/// engine, isolate and service locator.
abstract final class ReminderReconcileChannel {
  static const _channel = WindowMethodChannel(
    'au.com.sharpblue.nightmail/reminders',
    mode: ChannelMode.unidirectional,
  );

  static const _reconcileMethod = 'reconcile';

  /// Main window only: runs [onReconcile] whenever a sub-window asks.
  ///
  /// Safe to call more than once — re-registering only swaps the handler.
  static Future<void> listen(Future<void> Function() onReconcile) async {
    if (!AppWindow.isMain) return;
    try {
      await _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == _reconcileMethod) await onReconcile();
        return null;
      });
    } catch (e) {
      // Losing the channel costs immediacy, not correctness: the periodic
      // reconcile still catches everything on its next cycle.
      debugPrint('ReminderReconcileChannel.listen failed: $e');
    }
  }

  /// Sub-window only: asks the main window to reconcile now.
  ///
  /// Best-effort, and deliberately swallows failures — the main window may not
  /// have registered its handler yet, and the periodic reconcile is the safety
  /// net either way.
  static Future<void> requestReconcile() async {
    if (AppWindow.isMain) return;
    try {
      await _channel.invokeMethod<void>(_reconcileMethod);
    } catch (e) {
      debugPrint('ReminderReconcileChannel.requestReconcile failed: $e');
    }
  }
}
