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
///
/// **Which AES-GCM this actually is depends on `cryptography_flutter`**, which
/// registers itself automatically just by being a dependency (its `enable()` is
/// deprecated — do not add a call back). It supplies the OS implementation on
/// Android, iOS and macOS, and `BackgroundAesGcm` — the same Dart cipher moved
/// to a background isolate for large inputs — on Windows and Linux. Without it
/// this is pure Dart on the calling isolate, which for the UI isolate meant a
/// folder of a few hundred cached messages cost seconds before painting. The
/// bigger half of that fix is not spending the work at all: see
/// [CachedEmailDetails], which keeps bodies and inline images off the
/// folder-listing path.
class CacheEncryptionService {
  CacheEncryptionService(this._secureStorage);

  final FlutterSecureStorage _secureStorage;

  static const _keyStorageKey = 'nightmail_cache_aes_key';
  static const _legacyKeyFileName = '.nightmail_cache_aes_key';

  // AES-256-GCM: 12-byte nonce, 16-byte auth tag
  static final _algorithm = AesGcm.with256bits();

  SecretKey? _secretKey;
  Future<void>? _initFuture;

  Future<void> initialize() async {
    _initFuture ??= _loadOrGenerateKeyBytes().then((bytes) {
      _secretKey = SecretKey(bytes);
    });
    await _initFuture;
  }

  Future<String> encrypt(String plaintext) async {
    await initialize();
    final plaintextBytes = utf8.encode(plaintext);
    final secretBox = await _algorithm.encrypt(
      plaintextBytes,
      secretKey: _secretKey!,
    );
    // Concatenation: nonce (12) + ciphertext (n) + mac (16)
    return base64Encode(secretBox.concatenation());
  }

  Future<String> decrypt(String stored) async {
    await initialize();
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
