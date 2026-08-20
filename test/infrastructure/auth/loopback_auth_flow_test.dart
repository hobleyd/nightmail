import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/auth_browser_launcher.dart';
import 'package:nightmail/infrastructure/auth/loopback_auth_flow.dart';

/// The loopback half of macOS Gmail sign-in. Everything asserted here is a
/// property that fails silently in the real flow: a redirect resolved from the
/// wrong request hands the token exchange a URL with no code, and a port left
/// bound makes the *next* sign-in fail rather than this one.
void main() {
  /// Stands in for the native Chrome launch, and reports the URL it was given
  /// so the test can drive the redirect itself.
  late _RecordingLauncher launcher;

  setUp(() => launcher = _RecordingLauncher());

  /// A port nothing else is expected to be using; the real flow uses 34572.
  const port = 41599;

  Future<HttpClientResponse> get(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      return await request.close();
    } finally {
      client.close();
    }
  }

  test('completes with the full redirect URL, query string included', () async {
    final flow = LoopbackAuthFlow(launcher: launcher);
    final result = flow.authenticate(
      authorizationUrl: Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
      port: port,
    );

    await launcher.opened.future;
    final response = await get('/?code=abc123&scope=email');
    await response.drain<void>();

    expect(await result, 'http://127.0.0.1:$port/?code=abc123&scope=email');
  });

  test('carries an error response back rather than hanging — the caller reads '
      'error_description off it', () async {
    final flow = LoopbackAuthFlow(launcher: launcher);
    final result = flow.authenticate(
      authorizationUrl: Uri.parse('https://accounts.google.com/'),
      port: port,
    );

    await launcher.opened.future;
    final response = await get('/?error=access_denied');
    await response.drain<void>();

    expect(await result, contains('error=access_denied'));
  });

  test('ignores a request carrying no authorization response — the browser asks '
      'for /favicon.ico off the back of the landing page, and completing on the '
      'first request regardless resolves the flow with no code', () async {
    final flow = LoopbackAuthFlow(launcher: launcher);
    final result = flow.authenticate(
      authorizationUrl: Uri.parse('https://accounts.google.com/'),
      port: port,
    );

    await launcher.opened.future;
    final ignored = await get('/favicon.ico');
    await ignored.drain<void>();
    expect(ignored.statusCode, HttpStatus.notFound);

    final redirect = await get('/?code=second');
    await redirect.drain<void>();

    expect(await result, contains('code=second'));
  });

  test('opens the browser at the authorization URL it was given', () async {
    final flow = LoopbackAuthFlow(launcher: launcher);
    final authUrl = Uri.parse('https://accounts.google.com/o/oauth2/v2/auth?client_id=x');
    final result = flow.authenticate(authorizationUrl: authUrl, port: port);

    await launcher.opened.future;
    expect(launcher.urls.single, authUrl);

    final response = await get('/?code=abc');
    await response.drain<void>();
    await result;
    // Nothing brings the window back from Chrome on its own.
    expect(launcher.activated, isTrue);
  });

  test('releases the port on a timeout, so the next attempt can bind it',
      () async {
    final flow = LoopbackAuthFlow(
      launcher: launcher,
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      flow.authenticate(
        authorizationUrl: Uri.parse('https://accounts.google.com/'),
        port: port,
      ),
      throwsA(isA<AuthException>()),
    );

    // Would throw SocketException "address already in use" if the finally
    // clause had not closed the server.
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await second.close(force: true);
  });

  test('reports a port it cannot bind as an AuthException, not a raw '
      'SocketException the UI would show as a stack trace', () async {
    final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(() => blocker.close(force: true));

    await expectLater(
      LoopbackAuthFlow(launcher: launcher).authenticate(
        authorizationUrl: Uri.parse('https://accounts.google.com/'),
        port: port,
      ),
      throwsA(isA<AuthException>()),
    );
  });
}

class _RecordingLauncher extends AuthBrowserLauncher {
  _RecordingLauncher();

  final urls = <Uri>[];
  final opened = Completer<void>();
  bool activated = false;

  @override
  Future<void> open(Uri url) async {
    urls.add(url);
    if (!opened.isCompleted) opened.complete();
  }

  @override
  Future<void> activateThisApp() async => activated = true;
}
