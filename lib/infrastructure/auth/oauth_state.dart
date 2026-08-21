import 'dart:math';

import '../../core/error/exceptions.dart';

/// The `state` parameter of an OAuth2 authorization request (RFC 6749 §10.12):
/// a value this client mints, the provider echoes back on the redirect, and the
/// client checks before it spends the authorization code that arrived with it.
///
/// PKCE already stops a code somebody else injected from being *exchanged* —
/// the exchange carries this client's verifier, and an injected code was issued
/// against a different challenge. `state` covers the step before that: a
/// redirect that did not come from the authorization URL this client opened is
/// refused rather than acted on at all. It is also what keeps the loopback
/// listener from resolving the flow off a request that is not its redirect.
///
/// Never derive it from the PKCE verifier or challenge. The verifier is the
/// secret half of PKCE and this value travels in the URL, through the
/// browser's history and the provider's logs.
String generateOAuthState() {
  // Unreserved characters only, so the value survives the round trip through
  // the query string unchanged and compares equal on the way back.
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = Random.secure();
  return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
}

/// Shown when a redirect's `state` is absent or does not match. Deliberately
/// says nothing about which: the reader can do nothing differently either way,
/// and both mean the same thing — start again.
const oauthStateMismatchMessage =
    'Sign-in could not be verified: the response did not match the request '
    'that started it. Please try signing in again.';

/// Throws an [AuthException] unless [redirect] echoes [expected].
///
/// A **missing** `state` is a failure, not a skipped check — that is the whole
/// of the bypass this exists to close. It also makes the request side
/// self-enforcing: leaving `state` out of an authorization URL cannot fail
/// quietly, because the provider then echoes nothing back and the very first
/// sign-in fails loudly.
///
/// Only ever called for a redirect carrying a `code`. `state` protects the
/// code; an error response has nothing to spend, so it is reported as the
/// provider described it rather than as a mismatch.
void verifyOAuthState({required String expected, required Uri redirect}) {
  if (redirect.queryParameters['state'] == expected) return;
  throw const AuthException(message: oauthStateMismatchMessage);
}
