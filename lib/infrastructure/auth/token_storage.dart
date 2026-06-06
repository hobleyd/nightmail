import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_token.dart';

/// Persists [AuthToken] using platform-appropriate secure storage.
/// On mobile/desktop: OS keychain / keystore.
/// On web: encrypted localStorage (flutter_secure_storage web fallback).
class TokenStorage {
  TokenStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'nightmail_auth_token';

  Future<void> saveToken(AuthToken token) async {
    final json = jsonEncode(token.toJson());
    await _storage.write(key: _tokenKey, value: json);
  }

  Future<AuthToken?> loadToken() async {
    final json = await _storage.read(key: _tokenKey);
    if (json == null) return null;
    final map = jsonDecode(json) as Map<String, dynamic>;
    return AuthToken.fromStorageJson(map);
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }
}
