import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// Saving an out-of-office reply needs a scope neither provider grants at
/// sign-in, and both are requested incrementally — by the Save button, when
/// the user agrees.
///
/// Microsoft's has a trap the other incremental scopes do not:
/// `MailboxSettings.ReadWrite` *supersedes* the `MailboxSettings.Read` already
/// in the base set, so a substring test in the wrong direction reads every
/// existing account as already able to write, and the failure only shows up as
/// a 403 on Save.
GmailAuthService _gmail({List<String> extraScopes = const []}) =>
    GmailAuthService(
      clientId: 'client',
      clientSecret: '',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
      accountEmail: 'someone@contoso.com',
      extraScopes: extraScopes,
    );

MicrosoftAuthService _microsoft({List<String> extraScopes = const []}) =>
    MicrosoftAuthService(
      clientId: 'client',
      tenantId: 'common',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
      extraScopes: extraScopes,
    );

AuthToken _token(String scope) => AuthToken(
      accessToken: 'a',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'r',
      scope: scope,
    );

void main() {
  group('Microsoft', () {
    test('the write scope stays out of what a sign-in asks for', () {
      expect(
        MicrosoftAuthService.baseScopes,
        isNot(contains(MicrosoftAuthService.mailboxSettingsWriteScope)),
      );
      // The *read* half is in the base set and must stay there: it is what
      // lets the screen show the mailbox's current state before anybody is
      // asked for anything.
      expect(
        MicrosoftAuthService.baseScopes,
        contains('https://graph.microsoft.com/MailboxSettings.Read'),
      );
    });

    test('a token with only MailboxSettings.Read cannot write', () {
      expect(
        MicrosoftAuthService.grantsMailboxSettingsWrite(
            'openid profile Mail.ReadWrite MailboxSettings.Read'),
        isFalse,
      );
      expect(MicrosoftAuthService.grantsMailboxSettingsWrite(null), isFalse);
      expect(MicrosoftAuthService.grantsMailboxSettingsWrite(''), isFalse);
    });

    test('reads the grant off the token, however Microsoft spells it', () {
      expect(
        MicrosoftAuthService.grantsMailboxSettingsWrite(
            'openid profile MailboxSettings.ReadWrite'),
        isTrue,
      );
      expect(
        MicrosoftAuthService.grantsMailboxSettingsWrite(
            'https://graph.microsoft.com/MailboxSettings.ReadWrite Mail.Read'),
        isTrue,
      );
    });

    test('a refresh re-asks for a scope the token already carries', () {
      // The documented trap: a refresh names the scopes it wants, so
      // refreshing with the base list alone hands back a token *without* the
      // write scope an hour after it was granted.
      expect(
        _microsoft().refreshScopesFor(_token('Mail.Read MailboxSettings.ReadWrite')),
        contains(MicrosoftAuthService.mailboxSettingsWriteScope),
      );
      // And never asks for one that was not consented to — that fails the
      // refresh outright, which would lock the account out of everything.
      expect(
        _microsoft().refreshScopesFor(_token('Mail.Read MailboxSettings.Read')),
        isNot(contains(MicrosoftAuthService.mailboxSettingsWriteScope)),
      );
    });
  });

  group('Gmail', () {
    test('the settings scope stays out of what a sign-in asks for', () {
      for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
        expect(
          GmailAuthService.scopesForAccount(email),
          isNot(contains(GmailAuthService.mailSettingsScope)),
          reason: '$email',
        );
      }
    });

    test('the incremental request is what puts it in the authorization URL',
        () {
      expect(
        _gmail(extraScopes: const [GmailAuthService.mailSettingsScope])
            .requestedScopes,
        contains(GmailAuthService.mailSettingsScope),
      );
      expect(
        _gmail().requestedScopes,
        isNot(contains(GmailAuthService.mailSettingsScope)),
      );
      // Alongside the mail scopes, not instead of them.
      expect(
        _gmail(extraScopes: const [GmailAuthService.mailSettingsScope])
            .requestedScopes,
        contains('https://www.googleapis.com/auth/gmail.modify'),
      );
    });

    test('gmail.modify alone cannot write the responder', () {
      // Reading it can — `users.settings.getVacation` accepts gmail.modify —
      // which is why the screen loads for every account and only Save asks.
      expect(
        GmailAuthService.grantsMailSettingsAccess(
            'openid email https://www.googleapis.com/auth/gmail.modify'),
        isFalse,
      );
    });

    test('the full-mailbox scope already covers it', () {
      // An account that granted https://mail.google.com/ for permanently
      // deleting mail must not be asked a second time for something it can
      // already do.
      expect(
        GmailAuthService.grantsMailSettingsAccess(
            'openid https://mail.google.com/'),
        isTrue,
      );
      expect(
        GmailAuthService.grantsMailSettingsAccess(
            'openid https://www.googleapis.com/auth/gmail.settings.basic'),
        isTrue,
      );
    });
  });
}
