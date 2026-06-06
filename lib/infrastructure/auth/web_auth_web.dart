// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
// This file is web-only and is loaded exclusively via the conditional import:
//   import '…stub.dart' if (dart.library.html) '…web.dart'
// The linter doesn't know about the conditional import guard.
import 'dart:async';
import 'dart:html' as html;

/// Opens [url] in a popup and awaits the OAuth callback via [BroadcastChannel].
///
/// Microsoft's login pages set `Cross-Origin-Opener-Policy: same-origin-allow-popups`,
/// which severs `window.opener` when the popup navigates cross-origin back to
/// localhost. [BroadcastChannel] communicates between same-origin windows without
/// needing `window.opener`, so it works reliably across the full redirect chain.
Future<String> authenticateWeb(String url) {
  final completer = Completer<String>();

  final channel = html.BroadcastChannel('nightmail_auth');
  StreamSubscription? sub;

  sub = channel.onMessage.listen((event) {
    final data = event.data as String?;
    if (data != null && !completer.isCompleted) {
      sub?.cancel();
      channel.close();
      completer.complete(data);
    }
  });

  html.window.open(
    url,
    '_blank',
    'width=520,height=680,scrollbars=yes,resizable=yes',
  );

  return completer.future.timeout(
    const Duration(minutes: 10),
    onTimeout: () {
      sub?.cancel();
      channel.close();
      throw TimeoutException(
        'Authentication timed out',
        const Duration(minutes: 10),
      );
    },
  );
}
