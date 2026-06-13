import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CalDavCredentialStorage {
  CalDavCredentialStorage(this._storage);

  final FlutterSecureStorage _storage;

  Future<void> savePassword(String accountId, String password) async {
    await _storage.write(key: 'caldav_password_$accountId', value: password);
  }

  Future<String?> loadPassword(String accountId) async {
    return _storage.read(key: 'caldav_password_$accountId');
  }

  Future<void> deletePassword(String accountId) async {
    await _storage.delete(key: 'caldav_password_$accountId');
  }
}
