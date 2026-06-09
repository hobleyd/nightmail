import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Manages the AES-256-GCM key used to encrypt cached email content.
///
/// Each [encrypt] call generates a fresh 96-bit nonce prepended to the
/// ciphertext + auth tag as a single base64 blob. Running `strings` on the
/// SQLite file reveals only UUIDs and timestamps — no user-readable content.
class CacheEncryptionService {
  CacheEncryptionService(this._secureStorage);

  final FlutterSecureStorage _secureStorage;

  static const _keyStorageKey = 'nightmail_cache_aes_key';
  static const _legacyKeyFileName = '.nightmail_cache_aes_key';

  // AES-256-GCM: 12-byte nonce, 16-byte auth tag
  static final _algorithm = AesGcm.with256bits();

  SecretKey? _secretKey;

  Future<void> initialize() async {
    final keyBytes = await _loadOrGenerateKeyBytes();
    _secretKey = SecretKey(keyBytes);
  }

  Future<String> encrypt(String plaintext) async {
    final plaintextBytes = utf8.encode(plaintext);
    final secretBox = await _algorithm.encrypt(
      plaintextBytes,
      secretKey: _secretKey!,
    );
    // Concatenation: nonce (12) + ciphertext (n) + mac (16)
    return base64Encode(secretBox.concatenation());
  }

  Future<String> decrypt(String stored) async {
    final bytes = base64Decode(stored);
    final secretBox = SecretBox.fromConcatenation(
      bytes,
      nonceLength: _algorithm.nonceLength,
      macLength: _algorithm.macAlgorithm.macLength,
    );
    final decryptedBytes =
        await _algorithm.decrypt(secretBox, secretKey: _secretKey!);
    return utf8.decode(decryptedBytes);
  }

  Future<List<int>> _loadOrGenerateKeyBytes() async {
    // One-time migration from plain file to Keychain on desktop platforms.
    await _migrateLegacyFile();

    final existing = await _secureStorage.read(key: _keyStorageKey);
    if (existing != null) return base64Decode(existing);

    final key = await _algorithm.newSecretKey();
    final keyBytes = await key.extractBytes();
    await _secureStorage.write(
        key: _keyStorageKey, value: base64Encode(keyBytes));
    return keyBytes;
  }

  Future<void> _migrateLegacyFile() async {
    if (kIsWeb || (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux)) return;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_legacyKeyFileName');
    if (!file.existsSync()) return;
    try {
      final encoded = file.readAsStringSync().trim();
      final existing = await _secureStorage.read(key: _keyStorageKey);
      if (existing == null) {
        await _secureStorage.write(key: _keyStorageKey, value: encoded);
      }
      await file.delete();
    } catch (_) {
      // Best-effort; a new key will be generated if migration fails.
    }
  }
}
