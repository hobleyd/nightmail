import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Legacy storage for the OAuth application Client IDs/Secret/Tenant ID that
/// used to be shared app-wide across every account of a provider.
///
/// No longer written to: Client ID/Secret/Tenant ID now live on the Account
/// itself (`MicrosoftAccount.clientId`, `GmailAccount.clientId`/
/// `clientSecret`) — a value shared across every account of a provider meant
/// signing in to, or editing, ANY account could silently swap the
/// credentials every OTHER account's token refresh depended on. This class
/// only still exists so `AccountManager._migrateSharedClientIdsToAccounts`
/// can do a one-time read of whatever was last saved here and back it onto
/// any account created before that change.
class OAuthClientIdStorage {
  const OAuthClientIdStorage(this._storage);
  final FlutterSecureStorage _storage;

  static const _msKey = 'oauth_ms_client_id';
  static const _googleKey = 'oauth_google_client_id';
  static const _googleSecretKey = 'oauth_google_client_secret';

  Future<String?> loadMicrosoftClientId() => _storage.read(key: _msKey);
  Future<String?> loadGoogleClientId() => _storage.read(key: _googleKey);
  Future<String?> loadGoogleClientSecret() =>
      _storage.read(key: _googleSecretKey);
}
