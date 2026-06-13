import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';
import 'oauth_credentials.dart';

class OAuthCredentialsStorage {
  OAuthCredentialsStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _msClientId = 'oauth_microsoft_client_id';
  static const _msTenantId = 'oauth_microsoft_tenant_id';
  static const _msRedirectUri = 'oauth_microsoft_redirect_uri';
  static const _googleClientId = 'oauth_google_client_id';
  static const _googleRedirectUri = 'oauth_google_redirect_uri';

  /// Loads stored credentials, falling back to compile-time defaults for any
  /// key that has not yet been set. On first call the defaults are persisted
  /// so that subsequent loads are fully independent of the build environment.
  Future<OAuthCredentials> load() async {
    final msClientId = await _storage.read(key: _msClientId);
    final credentials = OAuthCredentials(
      microsoftClientId:
          msClientId ?? AppConfig.microsoftClientId,
      microsoftTenantId:
          await _storage.read(key: _msTenantId) ?? AppConfig.microsoftTenantId,
      microsoftRedirectUri: await _storage.read(key: _msRedirectUri) ??
          AppConfig.microsoftRedirectUri,
      googleClientId:
          await _storage.read(key: _googleClientId) ?? AppConfig.gmailClientId,
      googleRedirectUri: await _storage.read(key: _googleRedirectUri) ??
          AppConfig.gmailRedirectUri,
    );
    if (msClientId == null) await save(credentials);
    return credentials;
  }

  Future<void> save(OAuthCredentials credentials) async {
    await _storage.write(
        key: _msClientId, value: credentials.microsoftClientId);
    await _storage.write(
        key: _msTenantId, value: credentials.microsoftTenantId);
    await _storage.write(
        key: _msRedirectUri, value: credentials.microsoftRedirectUri);
    await _storage.write(
        key: _googleClientId, value: credentials.googleClientId);
    await _storage.write(
        key: _googleRedirectUri, value: credentials.googleRedirectUri);
  }
}
