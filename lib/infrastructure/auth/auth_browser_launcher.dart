import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Hands a sign-in URL to a real browser, preferring Google Chrome.
///
/// Chrome is asked for **by name**, not by taking the system default browser.
/// That is the whole point of the loopback flow on macOS: the user is already
/// signed into Google in Chrome, and a default browser of Safari or Firefox
/// would put them in front of a fresh sign-in every time.
class AuthBrowserLauncher {
  const AuthBrowserLauncher();

  static const _channel =
      MethodChannel('au.com.sharpblue.nightmail/browser_launcher');

  static bool get _isMacOS => !kIsWeb && Platform.isMacOS;

  /// Opens [url] in Chrome, falling back to the system default browser when
  /// Chrome is not installed or the native call is unavailable.
  Future<void> open(Uri url) async {
    if (_isMacOS) {
      // Native LaunchServices rather than `open -a "Google Chrome"`: spawning
      // a process is denied by the App Sandbox that release builds run under,
      // so the shell route would work in debug and ship broken.
      final opened = await _invoke<bool>(
        'openInChrome',
        arguments: {'url': url.toString()},
      );
      if (opened ?? false) return;
    }
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// Brings NightMail back to the front once the browser has handed the
  /// authorization code back. Without this the user is left looking at the
  /// browser with no sign anything happened.
  Future<void> activateThisApp() async {
    if (!_isMacOS) return;
    await _invoke<void>('activate');
  }

  Future<T?> _invoke<T>(String method, {Object? arguments}) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[AuthBrowserLauncher] $method failed: $e');
        return true;
      }());
      return null;
    } on MissingPluginException catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[AuthBrowserLauncher] $method unavailable: $e');
        return true;
      }());
      return null;
    }
  }
}
