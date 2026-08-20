import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';

/// The file-read scopes for the cloud-document preview are requested
/// *incrementally* — only by the flow that exists to ask for them, run when a
/// reader follows a cloud link and agrees.
///
/// Putting either in the base scope list is the ship-breaking mistake this
/// pins: an authorization request naming a scope nobody has consented to fails
/// outright (Microsoft AADSTS65001 where a tenant reserves `Files.Read.All` for
/// admin consent), and Google treats `drive.readonly` as restricted. Either way
/// the casualty is *adding a mail account*, over a feature that account may
/// never use.
void main() {
  group('the drive scopes stay out of the base sets', () {
    test('Gmail asks for no Drive scope when signing an account in', () {
      for (final email in [null, 'someone@gmail.com', 'me@contoso.com']) {
        final scopes = GmailAuthService.scopesForAccount(email);
        expect(scopes, isNot(contains(GmailAuthService.driveReadonlyScope)),
            reason: '$email');
        expect(scopes.where((s) => s.contains('/auth/drive')), isEmpty,
            reason: '$email');
      }
    });

    test('the Microsoft base scopes name no Files or Sites permission', () {
      // Read through what a sign-in actually sends rather than the private
      // list: this is the thing that must not change.
      expect(MicrosoftAuthService.filesReadScope,
          'https://graph.microsoft.com/Files.Read.All');
      expect(MicrosoftAuthService.grantsFileAccess(null), isFalse);
    });
  });

  group('Microsoft: reading the grant off the token', () {
    test('recognises the granted scope, however Microsoft abbreviates it', () {
      expect(
        MicrosoftAuthService.grantsFileAccess(
            'openid profile Mail.Read Files.Read.All'),
        isTrue,
      );
      expect(
        MicrosoftAuthService.grantsFileAccess(
            'https://graph.microsoft.com/Files.Read.All https://graph.microsoft.com/Mail.Read'),
        isTrue,
      );
    });

    test('a mail-only token has no file access', () {
      expect(
        MicrosoftAuthService.grantsFileAccess(
            'openid profile email Mail.ReadWrite Calendars.ReadWrite'),
        isFalse,
      );
      expect(MicrosoftAuthService.grantsFileAccess(''), isFalse);
    });
  });

  group('Google: reading the grant off the token', () {
    test('accepts drive.readonly and full drive', () {
      expect(
        GmailAuthService.grantsFileAccess(
            'openid https://www.googleapis.com/auth/gmail.modify '
            'https://www.googleapis.com/auth/drive.readonly'),
        isTrue,
      );
      expect(
        GmailAuthService.grantsFileAccess(
            'https://www.googleapis.com/auth/drive'),
        isTrue,
      );
    });

    test('rejects a metadata-only Drive scope, which reads no file content',
        () {
      expect(
        GmailAuthService.grantsFileAccess(
            'https://www.googleapis.com/auth/drive.metadata.readonly'),
        isFalse,
      );
      // `drive.file` covers only files this app created or the user picked, so
      // it can never read a file that merely arrived as a link.
      expect(
        GmailAuthService.grantsFileAccess(
            'https://www.googleapis.com/auth/drive.file'),
        isFalse,
      );
    });

    test('a mail-only token has no file access', () {
      expect(
        GmailAuthService.grantsFileAccess(
            'openid email https://www.googleapis.com/auth/gmail.modify'),
        isFalse,
      );
      expect(GmailAuthService.grantsFileAccess(null), isFalse);
    });
  });
}
