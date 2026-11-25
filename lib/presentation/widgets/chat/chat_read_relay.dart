import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/platform/window_utils.dart';
import '../../../domain/repositories/chat_repository.dart';
import 'chat_window_target.dart';

/// Tells the other window when a conversation is read, so the Chat pane (main
/// window) and the chat window — each its own isolate, with its own
/// repository and unread poll — agree at once rather than a poll later.
///
/// Every [ChatRepository.markRead] here (`readKeys` with `here`) is passed
/// on: from the main window to the open chat window through its window
/// method handler (as [ChatWindowTarget.openMethod] is), from the chat window
/// to the main window over a [ChannelMode.unidirectional] channel, as
/// `ChatConsentChannel` does. The receiver takes it as
/// [ChatRepository.readElsewhere], which is never passed on again.
abstract final class ChatReadRelay {
  static const _channel = WindowMethodChannel(
    'au.com.sharpblue.nightmail/chat_read',
    mode: ChannelMode.unidirectional,
  );

  static const method = 'chatRead';

  static StreamSubscription<void>? _forwarding;

  /// Starts passing this window's reads on, and — in the main window —
  /// taking the chat window's. Safe to call repeatedly.
  static void start(ChatRepository repository) {
    _forwarding ??= repository.readKeys
        .where((r) => r.here)
        .listen((r) => unawaited(_send(r.accountId, r.key)));
    if (!AppWindow.isMain) return;
    unawaited(() async {
      try {
        await _channel.setMethodCallHandler((MethodCall call) async {
          handle(call, repository);
          return null;
        });
      } catch (e) {
        // Costs immediacy only: the next unread poll catches up.
        debugPrint('[Chat] read relay unavailable: $e');
      }
    }());
  }

  /// Takes a read the other window passed on; false for any other call.
  static bool handle(MethodCall call, ChatRepository repository) {
    if (call.method != method) return false;
    final args = call.arguments;
    if (args is Map &&
        args['accountId'] is String &&
        args['key'] is String) {
      repository.readElsewhere(
          args['accountId'] as String, args['key'] as String);
    }
    return true;
  }

  static Future<void> _send(String accountId, String key) async {
    final args = {'accountId': accountId, 'key': key};
    try {
      if (AppWindow.isMain) {
        final window = await findSubWindow(ChatWindowTarget.windowType);
        await window?.invokeMethod<void>(method, args);
      } else {
        await _channel.invokeMethod<void>(method, args);
      }
    } catch (e) {
      debugPrint('[Chat] could not pass a read on: $e');
    }
  }
}
