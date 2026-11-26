import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/error/exceptions.dart';
import '../../core/platform/window_utils.dart';

/// Lets the chat window have the *main* window run a chat consent sign-in.
///
/// The consent replaces the account's token in the Keychain. Run from the
/// chat window's own isolate, the main window's auth service would go on
/// refreshing from what it last read — without the new scopes — and the next
/// refresh would quietly hand back a token without chat or channels (see
/// `MicrosoftAuthService._refreshScopes`). So every consent runs where the
/// accounts live, and the window waits for the answer.
///
/// [ChannelMode.unidirectional], as `MailSentChannel`: the main window is the
/// sole handler, any sub-window may invoke it.
abstract final class ChatConsentChannel {
  static const _channel = WindowMethodChannel(
    'au.com.sharpblue.nightmail/chat_consent',
    mode: ChannelMode.unidirectional,
  );

  static const _method = 'requestChatAccess';
  static const _callsMethod = 'requestCallAccess';

  /// A browser sign-in can sit for as long as the user takes; the auth flow
  /// itself gives up at five minutes.
  static const _timeout = Duration(minutes: 6);

  /// Main window only: answers consent requests with [run].
  /// [calls] answers the calling consent (Google Meet) the same way.
  static Future<void> listen(
    Future<({bool chats, bool channels})> Function(
      String accountId, {
      bool channels,
    }) run, {
    Future<bool> Function(String accountId)? calls,
  }) async {
    if (!AppWindow.isMain) return;
    try {
      await _channel.setMethodCallHandler((MethodCall call) async {
        final args = call.arguments is Map ? call.arguments as Map : const {};
        final accountId = args['accountId'] as String?;
        if (accountId == null) return null;
        if (call.method == _callsMethod && calls != null) {
          try {
            return {'granted': await calls(accountId)};
          } on AuthException catch (e) {
            return {'error': e.message};
          } catch (e) {
            return {'error': e.toString()};
          }
        }
        if (call.method != _method) return null;
        try {
          final r = await run(accountId,
              channels: args['channels'] as bool? ?? false);
          return {'chats': r.chats, 'channels': r.channels};
        } on AuthException catch (e) {
          return {'error': e.message};
        } catch (e) {
          return {'error': e.toString()};
        }
      });
    } catch (e) {
      debugPrint('ChatConsentChannel.listen failed: $e');
    }
  }

  /// Sub-window only: asks the main window to run the calling consent.
  static Future<bool> requestCalls(String accountId) async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>(
          _callsMethod, {'accountId': accountId}).timeout(_timeout);
    } catch (e) {
      throw AuthException(
          message: 'Could not reach the main NightMail window: $e');
    }
    if (reply is! Map) {
      throw const AuthException(
          message: 'The main NightMail window did not answer.');
    }
    final error = reply['error'];
    if (error is String) throw AuthException(message: error);
    return reply['granted'] == true;
  }

  /// Sub-window only: asks the main window to run the consent.
  static Future<({bool chats, bool channels})> request(
    String accountId, {
    required bool channels,
  }) async {
    final Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>(_method, {
        'accountId': accountId,
        'channels': channels,
      }).timeout(_timeout);
    } catch (e) {
      throw AuthException(
          message: 'Could not reach the main NightMail window: $e');
    }
    if (reply is! Map) {
      throw const AuthException(
          message: 'The main NightMail window did not answer.');
    }
    final error = reply['error'];
    if (error is String) throw AuthException(message: error);
    return (
      chats: reply['chats'] == true,
      channels: reply['channels'] == true,
    );
  }
}
