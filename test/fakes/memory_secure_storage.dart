import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Keychain that lives in a map — read and write are all the Slack
/// workspace store uses.
class MemorySecureStorage extends Fake implements FlutterSecureStorage {
  final values = <String, String>{};

  /// Reads from this one on (counting from 0) throw, as a locked Mac's
  /// Keychain does (-25308); null never.
  int? failReadsFrom;
  var _reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final failFrom = failReadsFrom;
    if (failFrom != null && _reads++ >= failFrom) {
      throw PlatformException(
          code: 'Unexpected security result code',
          message: 'User interaction is not allowed.');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
