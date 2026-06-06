import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Stores IMAP app passwords securely.
///
/// Storage strategy:
/// - Mobile / Web: [FlutterSecureStorage] (Keychain / Keystore).
/// - Desktop (macOS / Windows / Linux): plain file in app support directory.
///   macOS Keychain requires a Developer Team ID and proper entitlements that
///   are not available in ad-hoc or unsigned debug builds; the file approach
///   avoids that dependency.
class ImapCredentialStorage {
  ImapCredentialStorage(this._storage);

  final FlutterSecureStorage _storage;

  static bool get _useFile =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> savePassword(String accountId, String password) async {
    if (_useFile) {
      await (await _file(accountId)).writeAsString(password);
    } else {
      await _storage.write(key: _key(accountId), value: password);
    }
  }

  Future<String?> loadPassword(String accountId) async {
    if (_useFile) {
      final file = await _file(accountId);
      if (!file.existsSync()) return null;
      return file.readAsString();
    } else {
      return _storage.read(key: _key(accountId));
    }
  }

  Future<void> deletePassword(String accountId) async {
    if (_useFile) {
      final file = await _file(accountId);
      if (file.existsSync()) await file.delete();
    } else {
      await _storage.delete(key: _key(accountId));
    }
  }

  String _key(String accountId) => 'imap_password_$accountId';

  Future<File> _file(String accountId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/.imap_pw_$accountId');
  }
}
