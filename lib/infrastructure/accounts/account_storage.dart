import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'account.dart';

class AccountStorage {
  AccountStorage(this._storage);

  final FlutterSecureStorage _storage;

  // No accessibility filter: reads items regardless of their kSecAttrAccessible
  // attribute. Used on iOS to find items stored with the old WhenUnlocked class
  // so they can be lazily migrated to AfterFirstUnlockThisDeviceOnly.
  static const _migrationStorage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: null),
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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
      var json = await _storage.read(key: _accountsKey);

      // iOS lazy migration: if the item isn't found under the new accessibility
      // class (AfterFirstUnlock), check whether it exists under any class. This
      // handles the window between an app update (which changes iOptions) and the
      // first successful bulk migration (which runs at startup but may be skipped
      // if protected data is unavailable during a notification-tap launch).
      if (json == null && !kIsWeb && Platform.isIOS) {
        // This read uses no accessibility filter. If the item has WhenUnlocked
        // accessibility and the device is in a background execution context,
        // iOS returns -25308 (errSecInteractionNotAllowed). We let that error
        // propagate so AccountCubit can retry once protected data is available.
        final legacyJson = await _migrationStorage.read(key: _accountsKey);
        if (legacyJson != null) {
          // Migrate: delete (accessibility-blind) then write with new class.
          await _storage.delete(key: _accountsKey);
          await _storage.write(key: _accountsKey, value: legacyJson);
          final legacyIndex =
              await _migrationStorage.read(key: _activeIndexKey);
          if (legacyIndex != null) {
            await _storage.delete(key: _activeIndexKey);
            await _storage.write(key: _activeIndexKey, value: legacyIndex);
          }
          json = legacyJson;
        }
      }

      if (json == null) return [];
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => Account.fromJson(e as Map<String, dynamic>))
          .toList();
    } on PlatformException catch (e) {
      // -25308 errSecInteractionNotAllowed: keychain inaccessible in background
      // execution context (e.g. notification-tap cold launch). Propagate so
      // AccountCubit can wait for protected data and retry.
      if (!kIsWeb && Platform.isIOS && e.details == -25308) rethrow;
      return [];
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
