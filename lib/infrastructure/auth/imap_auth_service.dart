import '../../core/error/exceptions.dart';
import 'auth_service.dart';
import 'auth_token.dart';
import 'imap_credential_storage.dart';

/// Adapter implementing [AuthService] for IMAP accounts.
///
/// IMAP uses stored app passwords rather than OAuth2. This adapter allows
/// [AccountManager] to treat all account types uniformly for sign-out and
/// credential existence checks.
class ImapAuthService implements AuthService {
  ImapAuthService({
    required this.accountId,
    required ImapCredentialStorage credentialStorage,
  }) : _credentialStorage = credentialStorage;

  final String accountId;
  final ImapCredentialStorage _credentialStorage;

  static final _farFuture = DateTime(2099, 12, 31);

  /// Not used for IMAP — credentials are entered via a setup form, not OAuth2.
  @override
  Future<AuthToken> signIn() {
    throw const AuthException(
        message: 'IMAP accounts are configured via the setup form, not OAuth2.');
  }

  /// Returns a synthetic non-expiring token if a password is stored.
  /// The IMAP datasource reads the password directly from [ImapCredentialStorage];
  /// this token is only used by [AccountManager] to check whether credentials exist.
  @override
  Future<AuthToken?> getStoredToken() async {
    final password = await _credentialStorage.loadPassword(accountId);
    if (password == null) return null;
    return AuthToken(
      accessToken: password,
      tokenType: 'Basic',
      expiresAt: _farFuture,
    );
  }

  /// IMAP passwords don't expire; return the same token unchanged.
  @override
  Future<AuthToken> refreshToken(AuthToken currentToken) async => currentToken;

  @override
  Future<void> signOut() async {
    await _credentialStorage.deletePassword(accountId);
  }
}
