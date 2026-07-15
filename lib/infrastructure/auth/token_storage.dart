import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'auth_token.dart';

class TokenStorage {
  TokenStorage(
    this._storage, {
    String storageKey = 'nightmail_auth_token',
  })  : _tokenKey = storageKey,
        _legacyFileName = '.$storageKey';

  final FlutterSecureStorage _storage;
  final String _tokenKey;
  final String _legacyFileName;

  /// The secure-storage key this instance reads/writes. Unique per account
  /// (`token_{id}`), so it doubles as the coalescing key for concurrent
  /// refreshes across the several datasources that share one account's token.
  String get storageKey => _tokenKey;

  Future<void> saveToken(AuthToken token) async {
    final json = jsonEncode(token.toJson());
    await _storage.write(key: _tokenKey, value: json);
  }

  Future<AuthToken?> loadToken() async {
    await _migrateLegacyFile();
    final json = await _storage.read(key: _tokenKey);
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AuthToken.fromStorageJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
    await _deleteLegacyFile();
  }

  // One-time migration: move token from plain file to Keychain then delete file.
  Future<void> _migrateLegacyFile() async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final file = await _legacyFile;
    if (!file.existsSync()) return;
    try {
      final json = await file.readAsString();
      final existing = await _storage.read(key: _tokenKey);
      if (existing == null) {
        await _storage.write(key: _tokenKey, value: json);
      }
      await file.delete();
    } catch (_) {
      // Best-effort; leave file if something goes wrong.
    }
  }

  Future<void> _deleteLegacyFile() async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final file = await _legacyFile;
    if (file.existsSync()) await file.delete();
  }

  Future<File> get _legacyFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_legacyFileName');
  }
}
