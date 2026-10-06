import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/platform/window_utils.dart';

/// Lets the compose sub-window tell the main window that a message was sent.
///
/// The folder listing lives in the main window, and a reply's Sent copy only
/// reaches that listing through a re-read of the folder — nothing in the poll
/// brings it in (see `EmailListBloc._onMessageSent`), and the sub-window has
/// its own engine with no list to refresh. The drafts-refresh relay is the
/// wrong carrier: it fires *before* the send, when the server draft is
/// deleted, so the refresh it causes cannot list the reply.
///
/// Registered [ChannelMode.unidirectional], like `ReminderReconcileChannel`:
/// the main window is the sole handler and any sub-window may invoke it. On a
/// phone the compose screen runs in the main window and hands its result back
/// through a callback instead, so [notify] is a no-op there.
abstract final class MailSentChannel {
  static const _channel = WindowMethodChannel(
    'au.com.sharpblue.nightmail/mail_sent',
    mode: ChannelMode.unidirectional,
  );

  static const _sentMethod = 'sent';
  static const _conversationIdKey = 'conversationId';
  static const _sentAtMsKey = 'sentAtMs';

  /// How long [notify] waits for the main window's answer before the compose
  /// window closes regardless.
  static const notifyTimeout = Duration(seconds: 2);

  /// Main window only: runs [onSent] whenever a sub-window reports a send.
  ///
  /// Safe to call more than once — re-registering only swaps the handler.
  static Future<void> listen(
    void Function({String? conversationId, required DateTime sentAt}) onSent,
  ) async {
    if (!AppWindow.isMain) return;
    try {
      await _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method != _sentMethod) return null;
        final args = call.arguments;
        final map = args is Map ? args : const <Object?, Object?>{};
        final sentAtMs = map[_sentAtMsKey];
        onSent(
          conversationId: map[_conversationIdKey] as String?,
          sentAt: sentAtMs is int
              ? DateTime.fromMillisecondsSinceEpoch(sentAtMs)
              : DateTime.now(),
        );
        return null;
      });
    } catch (e) {
      // Losing the channel costs immediacy, not correctness: the next poll of
      // a non-Inbox folder, or the user's own Refresh, still lists the reply.
      debugPrint('MailSentChannel.listen failed: $e');
    }
  }

  /// Main window only: stops listening.
  static Future<void> stopListening() async {
    if (!AppWindow.isMain) return;
    try {
      await _channel.setMethodCallHandler(null);
    } catch (e) {
      debugPrint('MailSentChannel.stopListening failed: $e');
    }
  }

  /// Sub-window only: reports a send to the main window.
  ///
  /// The compose window awaits this *before* it closes — the close tears its
  /// engine down, and a call still on the wire would go with it — but bounded
  /// by [notifyTimeout], so a main window that cannot answer never holds the
  /// window of a message that has already gone open. Best-effort otherwise.
  static Future<void> notify({
    String? conversationId,
    required DateTime sentAt,
  }) async {
    if (AppWindow.isMain) return;
    try {
      await _channel.invokeMethod<void>(_sentMethod, <String, Object?>{
        _conversationIdKey: conversationId,
        _sentAtMsKey: sentAt.millisecondsSinceEpoch,
      }).timeout(notifyTimeout);
    } catch (e) {
      debugPrint('MailSentChannel.notify failed: $e');
    }
  }
}
