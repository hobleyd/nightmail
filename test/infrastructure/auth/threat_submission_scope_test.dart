import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/microsoft_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// Reporting a message to Microsoft as phishing needs `ThreatSubmission.ReadWrite`,
/// which is requested *incrementally* — by the Report-phishing action, when the
/// user agrees — and never at sign-in.
///
/// Putting it in the base scope list is the ship-breaking mistake this pins:
/// Microsoft marks the scope admin-consent-required, so an authorization
/// request naming it fails outright (AADSTS65001) in every tenant whose
/// administrator has not approved it, and the casualty is *adding a mail
/// account*, over a button that account may never press.
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
  test('the scope stays out of what a sign-in asks for', () {
    expect(
      MicrosoftAuthService.baseScopes,
      isNot(contains(MicrosoftAuthService.threatSubmissionScope)),
    );
    expect(
      MicrosoftAuthService.baseScopes
          .where((s) => s.contains('ThreatSubmission')),
      isEmpty,
    );
  });

  group('reading the grant off the token', () {
    test('a mail-only token cannot report', () {
      expect(
        MicrosoftAuthService.grantsThreatSubmission(
            'openid profile Mail.ReadWrite MailboxSettings.Read'),
        isFalse,
      );
      expect(MicrosoftAuthService.grantsThreatSubmission(null), isFalse);
      expect(MicrosoftAuthService.grantsThreatSubmission(''), isFalse);
    });

    test('recognises the granted scope, however Microsoft spells it', () {
      expect(
        MicrosoftAuthService.grantsThreatSubmission(
            'openid profile ThreatSubmission.ReadWrite Mail.Read'),
        isTrue,
      );
      expect(
        MicrosoftAuthService.grantsThreatSubmission(
            'https://graph.microsoft.com/ThreatSubmission.ReadWrite '
            'https://graph.microsoft.com/Mail.Read'),
        isTrue,
      );
    });

    test('matches whole tokens: ThreatSubmission.Read is a prefix, not a grant',
        () {
      expect(
        MicrosoftAuthService.grantsThreatSubmission(
            'openid ThreatSubmission.Read Mail.Read'),
        isFalse,
      );
      // The .All variant is a different permission the refresh would not be
      // able to re-request; a token only ever carries what was asked for.
      expect(
        MicrosoftAuthService.grantsThreatSubmission(
            'ThreatSubmission.ReadWrite.All'),
        isFalse,
      );
    });
  });

  group('refreshing keeps the grant', () {
    test('a refresh re-requests the scope once the token carries it', () {
      final scopes = _microsoft().refreshScopesFor(
          _token('openid Mail.ReadWrite ThreatSubmission.ReadWrite'));
      expect(scopes, contains(MicrosoftAuthService.threatSubmissionScope));
    });

    test('and never asks for it on a token that was not granted it', () {
      // Asking for an unconsented scope fails the whole refresh, which would
      // sign the account out over a permission it never had.
      final scopes =
          _microsoft().refreshScopesFor(_token('openid Mail.ReadWrite'));
      expect(scopes,
          isNot(contains(MicrosoftAuthService.threatSubmissionScope)));
    });
  });
}
