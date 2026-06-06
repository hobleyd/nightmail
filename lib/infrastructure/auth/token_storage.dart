import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_token.dart';

/// Persists [AuthToken] using the most appropriate mechanism per platform:
///
/// - **iOS / Android / Web**: [FlutterSecureStorage] (Keychain / Keystore).
/// - **macOS / Windows / Linux**: JSON file in the app support directory.
///   The macOS Keychain requires a developer-signed binary; using a file
///   avoids the -34018 entitlement error during development with ad-hoc signing.
class TokenStorage {
  TokenStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'nightmail_auth_token';
  static const _fileName = '.nightmail_token';

  // Use file storage on desktop (non-web, non-mobile) platforms.
  static bool get _useFile =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> saveToken(AuthToken token) async {
    final json = jsonEncode(token.toJson());
    if (_useFile) {
      await (await _tokenFile).writeAsString(json);
    } else {
      await _storage.write(key: _tokenKey, value: json);
    }
  }

  Future<AuthToken?> loadToken() async {
    if (_useFile) {
      final file = await _tokenFile;
      if (!file.existsSync()) return null;
      try {
        final json = await file.readAsString();
        final map = jsonDecode(json) as Map<String, dynamic>;
        return AuthToken.fromStorageJson(map);
      } catch (_) {
        return null;
      }
    } else {
      final json = await _storage.read(key: _tokenKey);
      if (json == null) return null;
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AuthToken.fromStorageJson(map);
    }
  }

  Future<void> clearToken() async {
    if (_useFile) {
      final file = await _tokenFile;
      if (file.existsSync()) await file.delete();
    } else {
      await _storage.delete(key: _tokenKey);
    }
  }

  Future<File> get _tokenFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }
}
