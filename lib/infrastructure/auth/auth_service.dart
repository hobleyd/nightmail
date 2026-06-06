import 'auth_token.dart';

/// Abstract contract for authentication services.
abstract interface class AuthService {
  /// Initiates the OAuth2 sign-in flow. Returns a valid [AuthToken] on success.
  Future<AuthToken> signIn();

  /// Silently refreshes the access token. Throws [AuthException] if no
  /// refresh token is available or the refresh fails.
  Future<AuthToken> refreshToken(AuthToken currentToken);

  /// Returns the currently stored token, or null if the user is not signed in.
  Future<AuthToken?> getStoredToken();

  /// Signs out and clears all stored tokens.
  Future<void> signOut();
}
