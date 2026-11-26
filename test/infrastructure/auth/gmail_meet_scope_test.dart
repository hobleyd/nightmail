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
      accountEmail: 'me@contoso.com',
      extraScopes: extraScopes,
    );

/// Google Meet's `meetings.space.created`, for a call from a chat avatar: asked
/// for on the first call, never at sign-in, and never as one of the chat scopes
/// — `grantsChat` wants every one of those, so adding it there would send every
/// account that already chats back through consent.
void main() {
  test('it stays out of sign-in and out of the chat scopes', () {
    for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
      expect(GmailAuthService.scopesForAccount(email),
          isNot(contains(GmailAuthService.meetScope)));
    }
    expect(GmailAuthService.chatScopes,
        isNot(contains(GmailAuthService.meetScope)));
  });

  test('the incremental request puts it in the authorization URL, with the '
      'rest', () {
    final scopes =
        _service(extraScopes: const [GmailAuthService.meetScope])
            .requestedScopes;
    expect(scopes, contains(GmailAuthService.meetScope));
    expect(scopes, contains('https://www.googleapis.com/auth/gmail.modify'));
    expect(_service().requestedScopes,
        isNot(contains(GmailAuthService.meetScope)));
  });

  test('reads the grant off the token, by whole scope', () {
    expect(
        GmailAuthService.grantsMeet(
            'openid https://www.googleapis.com/auth/meetings.space.created'),
        isTrue);
    expect(
        GmailAuthService.grantsMeet(
            'https://www.googleapis.com/auth/meetings.space.readonly'),
        isFalse);
    expect(GmailAuthService.grantsMeet(null), isFalse);
    expect(GmailAuthService.grantsMeet(''), isFalse);
  });
}
