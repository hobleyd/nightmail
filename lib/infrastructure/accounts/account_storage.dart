import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart';

/// Persists the list of configured accounts and the active account index.
///
/// Storage strategy mirrors [TokenStorage]:
/// - Mobile/Web: [FlutterSecureStorage]
/// - Desktop: JSON files in app support directory
class AccountStorage {
  AccountStorage(this._storage);

  final FlutterSecureStorage _storage;

  static const _accountsKey = 'nightmail_accounts';
  static const _activeIndexKey = 'nightmail_active_index';
  static const _accountsFileName = '.nightmail_accounts';
  static const _activeIndexFileName = '.nightmail_active_index';

  static bool get _useFile =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<void> saveAccounts(List<Account> accounts) async {
    final json = jsonEncode(accounts.map((a) => a.toJson()).toList());
    if (_useFile) {
      await (await _accountsFile).writeAsString(json);
    } else {
      await _storage.write(key: _accountsKey, value: json);
    }
  }

  Future<List<Account>> loadAccounts() async {
    try {
      final String? json;
      if (_useFile) {
        final file = await _accountsFile;
        if (!file.existsSync()) return [];
        json = await file.readAsString();
      } else {
        json = await _storage.read(key: _accountsKey);
      }
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
    final value = index.toString();
    if (_useFile) {
      await (await _activeIndexFile).writeAsString(value);
    } else {
      await _storage.write(key: _activeIndexKey, value: value);
    }
  }

  Future<int> loadActiveIndex() async {
    try {
      final String? value;
      if (_useFile) {
        final file = await _activeIndexFile;
        if (!file.existsSync()) return 0;
        value = await file.readAsString();
      } else {
        value = await _storage.read(key: _activeIndexKey);
      }
      return int.tryParse(value ?? '0') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clear() async {
    if (_useFile) {
      final af = await _accountsFile;
      final ai = await _activeIndexFile;
      if (af.existsSync()) await af.delete();
      if (ai.existsSync()) await ai.delete();
    } else {
      await _storage.delete(key: _accountsKey);
      await _storage.delete(key: _activeIndexKey);
    }
  }

  Future<File> get _accountsFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_accountsFileName');
  }

  Future<File> get _activeIndexFile async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_activeIndexFileName');
  }
}
