import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/gmail_auth_service.dart';
import 'package:nightmail/infrastructure/auth/token_storage.dart';

/// The Admin SDK room-directory scope cannot be asked for unconditionally:
/// Google rejects the *entire* authorization request with `invalid_scope` when an
/// `admin.directory.*` scope is requested for a personal @gmail.com account, so
/// including it in the base scope list would break adding one at all.
void main() {
  final roomScope = GmailAuthService.roomDirectoryScope;

  group('room-directory scope gating', () {
    test('is omitted when the account is not yet known — the shape of adding a '
        'brand-new account, where the domain cannot be known in advance', () {
      expect(GmailAuthService.scopesForAccount(null), isNot(contains(roomScope)));
    });

    test('is omitted for a personal @gmail.com account', () {
      expect(GmailAuthService.scopesForAccount('someone@gmail.com'),
          isNot(contains(roomScope)));
    });

    test('is omitted for @googlemail.com, the other consumer domain', () {
      expect(GmailAuthService.scopesForAccount('someone@googlemail.com'),
          isNot(contains(roomScope)));
    });

    test('is requested for a Workspace domain', () {
      expect(GmailAuthService.scopesForAccount('me@contoso.com'),
          contains(roomScope));
    });

    test('ignores case and surrounding whitespace', () {
      expect(GmailAuthService.scopesForAccount('  Someone@GMAIL.com '),
          isNot(contains(roomScope)));
      expect(GmailAuthService.scopesForAccount('  Me@Contoso.COM '),
          contains(roomScope));
    });

    test('is omitted for a malformed address rather than guessed at', () {
      expect(GmailAuthService.scopesForAccount('not-an-address'),
          isNot(contains(roomScope)));
      expect(GmailAuthService.scopesForAccount('trailing@'),
          isNot(contains(roomScope)));
    });

    test('is requested for a new account added from the Google Workspace '
        'button — the address is not known yet, so the button decides', () {
      expect(GmailAuthService.scopesForAccount(null, workspace: true),
          contains(roomScope));
      expect(GmailAuthService.scopesForAccount('', workspace: true),
          contains(roomScope));
    });

    test('lets a known address overrule the Workspace button — a personal '
        'account must never be sent the scope', () {
      expect(
          GmailAuthService.scopesForAccount('someone@gmail.com',
              workspace: true),
          isNot(contains(roomScope)));
    });

    test('reaches the authorization request from the constructor flag', () {
      GmailAuthService service({required bool workspace}) => GmailAuthService(
            clientId: 'id',
            clientSecret: 'secret',
            redirectUri: 'http://127.0.0.1',
            tokenStorage: TokenStorage(const FlutterSecureStorage()),
            workspace: workspace,
          );

      expect(service(workspace: true).requestedScopes, contains(roomScope));
      expect(service(workspace: false).requestedScopes,
          isNot(contains(roomScope)));
    });

    test('always keeps the base scopes — the room scope is additive only', () {
      final base = GmailAuthService.scopesForAccount(null);
      final workspace = GmailAuthService.scopesForAccount('me@contoso.com');

      expect(workspace, containsAll(base));
      expect(workspace.length, base.length + 1);
    });
  });
}
