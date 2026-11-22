import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// Sharing a linked cloud file with recipients needs a *write* scope —
/// `Files.ReadWrite.All` on Microsoft, full `drive` on Google — asked for only
/// when the sender chooses "Share and send". The traps are the same as for the
/// read scope (see cloud_drive_scope_test.dart), plus one of its own: the
/// write scope's name starts with the read one's.
MicrosoftAuthService _microsoft() => MicrosoftAuthService(
      clientId: 'client',
      tenantId: 'common',
      redirectUri: 'nightmail://auth',
      tokenStorage: TokenStorage(const FlutterSecureStorage()),
    );

AuthToken _token(String scope) => AuthToken(
      accessToken: 'a',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
      refreshToken: 'r',
      scope: scope,
    );

void main() {
  test('neither write scope is asked for when signing an account in', () {
    expect(MicrosoftAuthService.baseScopes,
        isNot(contains(MicrosoftAuthService.filesReadWriteScope)));
    for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
      expect(GmailAuthService.scopesForAccount(email),
          isNot(contains(GmailAuthService.driveScope)));
    }
  });

  group('Microsoft', () {
    test('reads the write grant off the token, abbreviated or not', () {
      expect(MicrosoftAuthService.grantsFileWrite('openid Files.ReadWrite.All'),
          isTrue);
      expect(
          MicrosoftAuthService.grantsFileWrite(
              'https://graph.microsoft.com/Files.ReadWrite.All'),
          isTrue);
    });

    test('the read scope is not the write one', () {
      expect(MicrosoftAuthService.grantsFileWrite('openid Files.Read.All'),
          isFalse);
      expect(MicrosoftAuthService.grantsFileWrite(null), isFalse);
    });

    test('a write grant still counts as being able to read files', () {
      expect(MicrosoftAuthService.grantsFileAccess('Files.ReadWrite.All'),
          isTrue);
    });

    test('a refresh re-requests exactly the file scopes the token proves', () {
      final both = _microsoft()
          .refreshScopesFor(_token('openid Files.Read.All Files.ReadWrite.All'));
      expect(both, contains(MicrosoftAuthService.filesReadScope));
      expect(both, contains(MicrosoftAuthService.filesReadWriteScope));

      // Asking a refresh for Files.Read.All on a token consented only to the
      // write scope would fail the refresh outright.
      final writeOnly =
          _microsoft().refreshScopesFor(_token('openid Files.ReadWrite.All'));
      expect(writeOnly, contains(MicrosoftAuthService.filesReadWriteScope));
      expect(writeOnly, isNot(contains(MicrosoftAuthService.filesReadScope)));

      final readOnly =
          _microsoft().refreshScopesFor(_token('openid Files.Read.All'));
      expect(readOnly, contains(MicrosoftAuthService.filesReadScope));
      expect(
          readOnly, isNot(contains(MicrosoftAuthService.filesReadWriteScope)));
    });
  });

  group('Google', () {
    test('only full drive grants sharing', () {
      expect(
          GmailAuthService.grantsDriveWrite(
              'openid https://www.googleapis.com/auth/drive'),
          isTrue);
      expect(
          GmailAuthService.grantsDriveWrite(
              'https://www.googleapis.com/auth/drive.readonly'),
          isFalse);
      expect(
          GmailAuthService.grantsDriveWrite(
              'https://www.googleapis.com/auth/drive.file'),
          isFalse);
      expect(GmailAuthService.grantsDriveWrite(null), isFalse);
    });
  });
}
