import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('au.com.sharpblue.nightmail/window_utils');

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
