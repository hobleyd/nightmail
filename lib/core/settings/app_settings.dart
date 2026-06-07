import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  static const int defaultPollIntervalSeconds = 30;
  static const String _pollIntervalFile = 'poll_interval';

  static const bool defaultConfirmDeleteEmail = true;
  static const String _confirmDeleteEmailFile = 'confirm_delete_email';

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<int> loadPollIntervalSeconds() async {
    try {
      final file = await _file(_pollIntervalFile);
      if (await file.exists()) {
        final raw = (await file.readAsString()).trim();
        return int.tryParse(raw) ?? defaultPollIntervalSeconds;
      }
    } catch (_) {}
    return defaultPollIntervalSeconds;
  }

  Future<void> savePollIntervalSeconds(int seconds) async {
    try {
      final file = await _file(_pollIntervalFile);
      await file.writeAsString('$seconds');
    } catch (_) {}
  }

  Future<bool> loadConfirmDeleteEmail() async {
    try {
      final file = await _file(_confirmDeleteEmailFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return defaultConfirmDeleteEmail;
  }

  Future<void> saveConfirmDeleteEmail(bool value) async {
    try {
      final file = await _file(_confirmDeleteEmailFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }
}
