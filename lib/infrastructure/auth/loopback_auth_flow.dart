import 'dart:async';
import 'dart:io';

import '../../core/error/exceptions.dart';
import 'auth_browser_launcher.dart';

/// Runs an OAuth2 authorization-code flow through a loopback redirect
/// (RFC 8252 §7.3): bind 127.0.0.1, hand the authorization URL to a browser,
/// and wait for the provider to redirect back to that port.
///
/// This exists because `flutter_web_auth_2` cannot do it on macOS. Its macOS
/// implementation is the method channel alone — `ASWebAuthenticationSession`,
/// which always renders in Safari's WebKit and takes no say in which browser
/// is used. Its own Dart loopback server (`useWebview: false`) is registered
/// for Windows and Linux only, and it launches the *default* browser, so it
/// could not be pointed at Chrome either. Everything here is deliberately the
/// same shape as that server, because the details below are load-bearing.
class LoopbackAuthFlow {
  const LoopbackAuthFlow({
    this.launcher = const AuthBrowserLauncher(),
    this.timeout = const Duration(minutes: 5),
  });

  final AuthBrowserLauncher launcher;

  /// How long to wait for the redirect before giving up. Matches
  /// `flutter_web_auth_2`'s own default.
  final Duration timeout;

  /// Opens [authorizationUrl] and completes with the full redirect URL the
  /// provider sent back, query string included.
  Future<String> authenticate({
    required Uri authorizationUrl,
    required int port,
  }) async {
    final server = await _bind(port);
    try {
      await launcher.open(authorizationUrl);
      final redirect = await _awaitRedirect(server).timeout(timeout);
      await launcher.activateThisApp();
      return redirect;
    } on TimeoutException {
      throw const AuthException(
        message: 'Sign-in timed out waiting for the browser.',
      );
    } finally {
      // Unconditional: an abandoned sign-in that left the port bound would
      // make every later attempt fail on "address already in use".
      await server.close(force: true);
    }
  }

  Future<HttpServer> _bind(int port) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      throw AuthException(
        message: 'Could not listen on 127.0.0.1:$port for the sign-in '
            'redirect: ${e.osError?.message ?? e.message}',
      );
    }
  }

  Future<String> _awaitRedirect(HttpServer server) async {
    await for (final request in server) {
      final uri = request.requestedUri;
      final params = uri.queryParameters;
      if (!params.containsKey('code') && !params.containsKey('error')) {
        // Not every request on this port is the redirect — a browser will ask
        // for /favicon.ico off the back of the landing page, and some probe the
        // origin first. Completing on the first request regardless would
        // resolve the flow with a URL carrying no authorization code.
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      request.response.headers.contentType = ContentType.html;
      request.response.write(_landingPage);
      await request.response.close();
      return uri.toString();
    }
    throw const AuthException(message: 'Sign-in was cancelled.');
  }
}

const _landingPage = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>NightMail</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    text-align: center;
  }
  h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
  p { margin: 0; opacity: .7; }
</style>
</head>
<body>
  <main>
    <h1>You're signed in</h1>
    <p>You can close this tab and go back to NightMail.</p>
  </main>
</body>
</html>
''';
