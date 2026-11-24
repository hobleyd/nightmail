import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';

/// Google Chat's scopes are incremental, asked for the first time Chat opens
/// on a Workspace account — never at sign-in, where their consent screen would
/// stand in front of adding a mail account.
void main() {
  test('no chat scope is asked for when signing an account in', () {
    for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
      final scopes = GmailAuthService.scopesForAccount(email);
      for (final s in GmailAuthService.chatScopes) {
        expect(scopes, isNot(contains(s)));
      }
    }
  });

  test('chat needs every chat scope, matched exactly', () {
    final all = GmailAuthService.chatScopes.join(' ');
    expect(GmailAuthService.grantsChat(all), isTrue);
    expect(
        GmailAuthService.grantsChat(all.replaceFirst(
            'https://www.googleapis.com/auth/chat.messages ',
            'https://www.googleapis.com/auth/chat.messages.readonly ')),
        isFalse);
    expect(GmailAuthService.grantsChat(null), isFalse);
  });
}
