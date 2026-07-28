import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
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
