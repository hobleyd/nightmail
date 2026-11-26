// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
// This file is web-only and is loaded exclusively via the conditional import:
//   import '…stub.dart' if (dart.library.html) '…web.dart'
// The linter doesn't know about the conditional import guard.
import 'dart:async';
import 'dart:html' as html;

/// The browser refused to open the sign-in popup.
class PopupBlockedException implements Exception {
  const PopupBlockedException();

  @override
  String toString() =>
      'The browser blocked the sign-in window. Allow pop-ups for this site, '
      'then sign in again.';
}

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

  // A blocked popup gives no window back (`null`, which dart:html's
  // non-nullable WindowBase only reports by throwing). Fail now rather than
  // wait out the timeout behind a spinner. A popup's later `closed` is not
  // watched: Microsoft's COOP header severs the handle, which then reads as
  // closed while the sign-in is still going on.
  Object? popup;
  try {
    popup = html.window.open(
      url,
      '_blank',
      'width=520,height=680,scrollbars=yes,resizable=yes',
    );
  } catch (_) {
    popup = null;
  }
  if (popup == null) {
    sub.cancel();
    channel.close();
    return Future.error(const PopupBlockedException());
  }

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
