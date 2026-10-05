import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';

const _channel = MethodChannel('au.com.sharpblue.nightmail/window_utils');

/// Which engine the calling code is running in.
///
/// `desktop_multi_window` re-enters `main()` with a fresh `FlutterEngine` —
/// and so a fresh isolate, service locator and set of statics — for every
/// sub-window. Code that owns a *process-wide* resource must therefore run in
/// the main window only, and [isMain] is how it tells the difference.
abstract final class AppWindow {
  static bool _isMain = true;

  /// False when this engine belongs to a `desktop_multi_window` sub-window.
  /// Always true on mobile, which has no sub-windows.
  static bool get isMain => _isMain;

  /// Marks this engine as a sub-window. Called from `main()` before the
  /// service locator is configured; nothing else should call it.
  static void markAsSubWindow() => _isMain = false;
}

Future<Map<String, double>?> _getMyScreenInfo() async {
  try {
    final result =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('getMyScreenInfo');
    if (result == null) return null;
    return {
      'x': (result['x'] as num).toDouble(),
      'y': (result['y'] as num).toDouble(),
      'width': (result['width'] as num).toDouble(),
      'height': (result['height'] as num).toDouble(),
      'mainScreenHeight': (result['mainScreenHeight'] as num).toDouble(),
    };
  } catch (_) {
    return null;
  }
}

/// Creates a sub-window, embedding the calling window's screen frame in the
/// arguments so the sub-window can center itself on the same screen.
Future<WindowController> createSubWindow(WindowConfiguration config) async {
  final screenInfo = await _getMyScreenInfo();

  Map<String, dynamic> args;
  try {
    args = jsonDecode(config.arguments) as Map<String, dynamic>;
  } catch (_) {
    args = {};
  }

  if (screenInfo != null) {
    args['_screenInfo'] = screenInfo;
  }

  return WindowController.create(
    WindowConfiguration(arguments: jsonEncode(args)),
  );
}

/// The `type` a sub-window was created with, read back from the arguments
/// `desktop_multi_window` keeps for it. Null for the main window — the plugin
/// lists it with empty arguments — and for anything that isn't our JSON.
String? subWindowTypeOf(String arguments) {
  if (arguments.isEmpty) return null;
  try {
    final decoded = jsonDecode(arguments);
    return decoded is Map ? decoded['type'] as String? : null;
  } catch (_) {
    return null;
  }
}

/// The open sub-window of [type], if there is one.
///
/// Nothing on the Dart side can keep this list: a sub-window closes on its
/// own and its isolate dies with it, so the opener is never told. The
/// plugin's registry drops a window as it closes and remembers the arguments
/// each one was created with, which is where the type lives — so it is asked
/// every time rather than cached.
Future<WindowController?> findSubWindow(String type) async {
  final List<WindowController> all;
  try {
    all = await WindowController.getAll();
  } catch (_) {
    return null;
  }
  for (final window in all) {
    if (subWindowTypeOf(window.arguments) == type) return window;
  }
  return null;
}

/// Brings the sub-window of [type] to the front, creating it only if none is
/// open.
///
/// Calendar, Tasks and Commitments are one-of-a-kind views: a second window
/// would be the same thing twice, stacked behind the first. A window that
/// closed between the lookup and the `show` is treated as absent.
Future<WindowController> showOrCreateSubWindow(
  String type, {
  Map<String, dynamic> arguments = const {},
}) async {
  final existing = await findSubWindow(type);
  if (existing != null) {
    try {
      await existing.show();
      return existing;
    } catch (_) {
      // Gone since the lookup — open a fresh one below.
    }
  }
  return createSubWindow(
    WindowConfiguration(arguments: jsonEncode({'type': type, ...arguments})),
  );
}

Duration? _doubleClickInterval;

/// How long the OS waits for a second click before a click is just a click.
///
/// Flutter's [kDoubleTapTimeout] is 300 ms; macOS's default is 500 ms and the
/// user can make it longer still. A control that toggles on one click and
/// opens a window on two must use the OS's figure, or a double-click the OS
/// accepts arrives as two single clicks. Answered once and kept; falls back to
/// Flutter's value where the platform has no handler (Windows and Linux).
Future<Duration> platformDoubleClickInterval() async {
  final cached = _doubleClickInterval;
  if (cached != null) return cached;
  Duration? fromPlatform;
  try {
    final ms = await _channel.invokeMethod<num>('getDoubleClickIntervalMs');
    if (ms != null && ms > 0) {
      fromPlatform = Duration(milliseconds: ms.round());
    }
  } catch (_) {}
  return _doubleClickInterval = fromPlatform ?? kDoubleTapTimeout;
}

/// Forgets the cached interval so a test can mock a different answer.
@visibleForTesting
void resetPlatformDoubleClickInterval() => _doubleClickInterval = null;
