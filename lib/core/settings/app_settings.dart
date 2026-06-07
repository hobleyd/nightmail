import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppSettings {
  static const int defaultPollIntervalSeconds = 30;
  static const String _pollIntervalFile = 'poll_interval';

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
}
