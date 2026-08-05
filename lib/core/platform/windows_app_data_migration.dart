import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The `CompanyName` this app shipped with before it was corrected to
/// `au.com.sharpblue` in `windows/runner/Runner.rc`.
const String _legacyCompanyName = 'com.sharpblue';

/// `ProductName` from the same version block. Unchanged, but the old directory
/// cannot be located without it.
const String _productName = 'NightMail';

/// Moves Windows application data out of the directory the old `CompanyName`
/// put it in.
///
/// `path_provider_windows` derives `getApplicationSupportDirectory()` from the
/// executable's version resource as `%APPDATA%\<CompanyName>\<ProductName>`, so
/// correcting `CompanyName` from `com.sharpblue` to `au.com.sharpblue` also
/// moves that directory. Everything under it would otherwise be abandoned:
/// settings, window bounds, spam rules — and `flutter_secure_storage.dat`,
/// which on Windows is a *file* in this directory rather than an OS keystore
/// and holds every account, OAuth token and IMAP password. Without this the
/// rename reads to the user as being silently signed out of everything.
///
/// Safe to call on every launch and on every platform; it is a no-op once the
/// old directory is gone. Must run **before** anything resolves the support
/// directory — in practice before `configureDependencies()`.
Future<void> migrateWindowsAppDataDirectory() async {
  if (kIsWeb || !Platform.isWindows) return;

  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final legacyRoot = Directory('$appData\\$_legacyCompanyName');
  final legacy = Directory('${legacyRoot.path}\\$_productName');
  if (!legacy.existsSync()) return;

  final Directory current;
  try {
    current = await getApplicationSupportDirectory();
  } catch (_) {
    return;
  }

  // An old build whose CompanyName has not been corrected resolves to the very
  // directory being migrated; merging it into itself would be destructive.
  if (_samePath(legacy.path, current.path)) return;

  try {
    mergeAppDataInto(legacy, current);
    legacy.deleteSync(recursive: true);
    // Only if this app was the sole occupant of the old company directory.
    if (legacyRoot.listSync().isEmpty) legacyRoot.deleteSync();
  } catch (_) {
    // Best-effort. A partial move still leaves the destination usable, and the
    // next launch retries whatever is left behind.
  }
}

/// Recursively moves the contents of [from] into [to], creating [to] as needed.
///
/// An entry that already exists at the destination wins and the stale copy is
/// left to be deleted with the source tree — the app may have written defaults
/// into the new directory before this ran, and those are the newer truth.
@visibleForTesting
void mergeAppDataInto(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(followLinks: false)) {
    final name = entity.path.split(RegExp(r'[/\\]')).last;
    // Separator from the host, not a literal `\`: on Linux (where the tests
    // run) a backslash is an ordinary filename character, so a hardcoded one
    // makes a single file called `NightMail\<name>` beside the destination
    // directory instead of an entry inside it.
    final target = '${to.path}${Platform.pathSeparator}$name';

    if (entity is Directory) {
      mergeAppDataInto(entity, Directory(target));
    } else if (entity is File) {
      if (File(target).existsSync() || Directory(target).existsSync()) continue;
      try {
        entity.renameSync(target);
      } catch (_) {
        // rename fails across volumes and on a file another process holds open.
        try {
          entity.copySync(target);
        } catch (_) {}
      }
    }
  }
}

bool _samePath(String a, String b) =>
    a.toLowerCase().replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '') ==
    b.toLowerCase().replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '');
