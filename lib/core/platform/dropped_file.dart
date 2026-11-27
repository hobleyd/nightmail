import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;

/// The bytes of a file dragged in from the desktop (`desktop_drop`), for
/// the compose window and the chat conversation alike.
///
/// Windows can refuse Flutter's own read of a file dropped from some places
/// (a zip's contents, a OneDrive placeholder, a long path) that PowerShell
/// reads through the `\\?\` prefix, so a failed read there is tried again
/// that way before giving up.
Future<Uint8List> readDroppedFileBytes(DropItem file) async {
  try {
    return await file.readAsBytes();
  } catch (_) {
    if (kIsWeb || !Platform.isWindows) rethrow;
  }
  final winPath = r'\\?\' + file.path.replaceAll('/', r'\');
  final escaped = winPath.replaceAll("'", "''");
  final ps = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "[Convert]::ToBase64String([IO.File]::ReadAllBytes('$escaped'))",
  ]);
  if (ps.exitCode == 0) {
    final out = (ps.stdout as String).trim();
    if (out.isNotEmpty) return base64Decode(out);
  }
  return File(file.path).readAsBytes();
}

/// Whether a dropped item is a folder rather than a file.
bool isDroppedDirectory(DropItem file) =>
    file is DropItemDirectory ||
    !kIsWeb &&
        file.path.isNotEmpty &&
        FileSystemEntity.isDirectorySync(file.path);
