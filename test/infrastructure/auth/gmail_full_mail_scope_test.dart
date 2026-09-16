import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

GmailAuthService _service({List<String> extraScopes = const []}) =>
    GmailAuthService(
      clientId: 'client',
      clientSecret: '',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
      accountEmail: 'someone@gmail.com',
      extraScopes: extraScopes,
    );

/// Gmail's full-mailbox scope is what `messages.batchDelete` — the only
/// permanent delete Gmail has — accepts, and nothing less does. It is
/// requested *incrementally*, by the flow that empties the trash, for the same
/// reason the Drive scope is: Google classes it restricted, so naming it at
/// sign-in would put the heaviest consent screen it shows in front of adding a
/// mail account, over an action most accounts never take.
void main() {
  test('it stays out of what a sign-in asks for', () {
    for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
      final scopes = GmailAuthService.scopesForAccount(email);
      expect(scopes, isNot(contains(GmailAuthService.fullMailScope)),
          reason: '$email');
      expect(scopes.where((s) => s.contains('mail.google.com')), isEmpty,
          reason: '$email');
    }
  });

  // The half between the two: a scope excluded from the base list and read
  // back off the token still has to *reach* the authorization URL. Dropped
  // there it fails as a 403 a long way away, and every check against the token
  // it comes back with still passes, because the token simply does not carry
  // it.
  test('the incremental request is what puts it in the authorization URL', () {
    expect(
      _service(extraScopes: const [GmailAuthService.fullMailScope])
          .requestedScopes,
      contains(GmailAuthService.fullMailScope),
    );
    expect(
      _service().requestedScopes,
      isNot(contains(GmailAuthService.fullMailScope)),
    );
    // And it is asked for *alongside* the mail scopes, not instead of them —
    // an authorization request naming only the new one would drop the rest.
    expect(
      _service(extraScopes: const [GmailAuthService.fullMailScope])
          .requestedScopes,
      contains('https://www.googleapis.com/auth/gmail.modify'),
    );
  });

  test('reads the grant off the token', () {
    expect(
      GmailAuthService.grantsFullMailAccess(
          'openid email https://mail.google.com/'),
      isTrue,
    );
    // Google is not consistent about the trailing slash, and the scope means
    // the same thing either way.
    expect(
      GmailAuthService.grantsFullMailAccess('https://mail.google.com'),
      isTrue,
    );
  });

  test('the scopes a sign-in does grant are not mistaken for it', () {
    // Whole-token membership, not a substring test: every Gmail scope this app
    // holds is a googleapis.com URL, but `gmail.modify` cannot delete.
    expect(
      GmailAuthService.grantsFullMailAccess(
          'https://www.googleapis.com/auth/gmail.modify '
          'https://www.googleapis.com/auth/calendar.events'),
      isFalse,
    );
    expect(GmailAuthService.grantsFullMailAccess(null), isFalse);
    expect(GmailAuthService.grantsFullMailAccess(''), isFalse);
  });
}
