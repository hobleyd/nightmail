import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the OAuth application Client IDs for Microsoft and Google.
/// These are app-level credentials (one per provider, shared across all
/// accounts of that provider) entered by the user on first sign-in.
class OAuthClientIdStorage {
  const OAuthClientIdStorage(this._storage);
  final FlutterSecureStorage _storage;

  static const _msKey = 'oauth_ms_client_id';
  static const _googleKey = 'oauth_google_client_id';

  Future<String?> loadMicrosoftClientId() => _storage.read(key: _msKey);
  Future<String?> loadGoogleClientId() => _storage.read(key: _googleKey);

  Future<void> saveMicrosoftClientId(String id) =>
      _storage.write(key: _msKey, value: id);

  Future<void> saveGoogleClientId(String id) =>
      _storage.write(key: _googleKey, value: id);
}
