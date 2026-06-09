import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart';

class AccountStorage {
  AccountStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _accountsKey = 'nightmail_accounts';
  static const _activeIndexKey = 'nightmail_active_index';
  static const _accountsFileName = '.nightmail_accounts';
  static const _activeIndexFileName = '.nightmail_active_index';

  Future<void> saveAccounts(List<Account> accounts) async {
    final json = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await _storage.write(key: _accountsKey, value: json);
  }

  Future<List<Account>> loadAccounts() async {
    await _migrateLegacyFiles();
    try {
      final json = await _storage.read(key: _accountsKey);
      if (json == null) return [];
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => Account.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveActiveIndex(int index) async {
    await _storage.write(key: _activeIndexKey, value: index.toString());
  }

  Future<int> loadActiveIndex() async {
    try {
      final value = await _storage.read(key: _activeIndexKey);
      return int.tryParse(value ?? '0') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: _accountsKey);
    await _storage.delete(key: _activeIndexKey);
    await _deleteLegacyFiles();
  }

  // One-time migration: move account data from plain files to Keychain then delete files.
  Future<void> _migrateLegacyFiles() async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final dir = await getApplicationSupportDirectory();

    final accountsFile = File('${dir.path}/$_accountsFileName');
    if (accountsFile.existsSync()) {
      try {
        final json = await accountsFile.readAsString();
        final existing = await _storage.read(key: _accountsKey);
        if (existing == null) {
          await _storage.write(key: _accountsKey, value: json);
        }
        await accountsFile.delete();
      } catch (_) {}
    }

    final activeIndexFile = File('${dir.path}/$_activeIndexFileName');
    if (activeIndexFile.existsSync()) {
      try {
        final value = await activeIndexFile.readAsString();
        final existing = await _storage.read(key: _activeIndexKey);
        if (existing == null) {
          await _storage.write(key: _activeIndexKey, value: value.trim());
        }
        await activeIndexFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _deleteLegacyFiles() async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final dir = await getApplicationSupportDirectory();
    final accountsFile = File('${dir.path}/$_accountsFileName');
    final activeIndexFile = File('${dir.path}/$_activeIndexFileName');
    if (accountsFile.existsSync()) await accountsFile.delete();
    if (activeIndexFile.existsSync()) await activeIndexFile.delete();
  }
}
