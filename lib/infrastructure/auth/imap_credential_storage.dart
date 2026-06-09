import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class ImapCredentialStorage {
  ImapCredentialStorage(this._storage);

  final FlutterSecureStorage _storage;

  Future<void> savePassword(String accountId, String password) async {
    await _storage.write(key: _key(accountId), value: password);
  }

  Future<String?> loadPassword(String accountId) async {
    await _migrateLegacyFile(accountId);
    return _storage.read(key: _key(accountId));
  }

  Future<void> deletePassword(String accountId) async {
    await _storage.delete(key: _key(accountId));
    await _deleteLegacyFile(accountId);
  }

  String _key(String accountId) => 'imap_password_$accountId';

  // One-time migration: move password from plain file to Keychain then delete file.
  Future<void> _migrateLegacyFile(String accountId) async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final file = await _legacyFile(accountId);
    if (!file.existsSync()) return;
    try {
      final password = await file.readAsString();
      final existing = await _storage.read(key: _key(accountId));
      if (existing == null) {
        await _storage.write(key: _key(accountId), value: password);
      }
      await file.delete();
    } catch (_) {
      // Best-effort; leave file if something goes wrong.
    }
  }

  Future<void> _deleteLegacyFile(String accountId) async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final file = await _legacyFile(accountId);
    if (file.existsSync()) await file.delete();
  }

  Future<File> _legacyFile(String accountId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/.imap_pw_$accountId');
  }
}
