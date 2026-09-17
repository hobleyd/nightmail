import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_data_directory.dart';

/// The bundle identifier every previous macOS location is named after.
const String _bundleId = 'au.com.sharpblue.nightmail';

/// The cache database's file name, without the `.sqlite` extension drift adds.
const String _databaseName = 'nightmail_cache';

/// Gathers everything earlier macOS builds stored into [appDataDirectory].
///
/// Three places have held NightMail's data on macOS, and a user updating into
/// this build may have data in any of them:
///
/// * `~/Library/Containers/au.com.sharpblue.nightmail/Data/...` — the sandbox
///   container the release build wrote to until the sandbox was turned off.
/// * `~/Library/Application Support/au.com.sharpblue.nightmail` — where an
///   unsandboxed build resolved the support directory to.
/// * `~/Documents/nightmail_cache.sqlite` — drift's default is the *documents*
///   directory, which unsandboxed is the user's own Documents folder.
///
/// Accounts, OAuth tokens and IMAP passwords are **not** part of this. They live
/// in the Keychain under `keychain-access-groups`, which is unchanged and is why
/// that entitlement stays behind after the sandbox goes.
///
/// It copies rather than moves, with one exception: the database in
/// `~/Documents` is *taken*, because leaving it is leaving a file of ours in the
/// user's own folder, which is the thing `~/.nightmail` exists to stop. The two
/// Library locations are left alone — nothing is cluttered by them, and they are
/// the way back to an older build.
///
/// Safe on every launch and every platform: a no-op once the destination is
/// populated. Must run **before** anything resolves the data directory or opens
/// the database — in practice before `configureDependencies()`.
Future<void> migrateMacOSAppData() async {
  if (kIsWeb || !Platform.isMacOS) return;

  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return;

  final Directory destination;
  try {
    destination = await appDataDirectory();
  } catch (_) {
    return;
  }
  // HOME was unreadable and appDataDirectory fell back to the platform's own
  // support directory, which is one of the places being migrated *from*.
  if (!destination.path.endsWith('/$macOSAppDataDirectoryName')) return;

  final container = Directory('$home/Library/Containers/$_bundleId/Data');
  try {
    adoptMacOSAppData(
      supportDirectories: [
        // The container is the release build's own data and wins per file; the
        // Application Support copy is an unsandboxed build's and fills gaps.
        Directory('${container.path}/Library/Application Support/$_bundleId'),
        Directory('$home/Library/Application Support/$_bundleId'),
      ],
      databaseDirectories: [
        Directory('${container.path}/Documents'),
        Directory('$home/Documents'),
      ],
      takeDatabaseFrom: Directory('$home/Documents'),
      destination: destination,
    );
  } catch (_) {
    // Best effort. A partial copy still leaves a usable destination, and the
    // next launch retries whatever has not landed — nothing is removed except a
    // database already copied, so there is always something left to retry from.
  }
}

/// The copying half, with every directory named so it can be tested.
///
/// [supportDirectories] and [databaseDirectories] are each tried in order, and
/// the first entry that has a given file wins. A database found in
/// [takeDatabaseFrom] is deleted once it has been copied; one found anywhere
/// else is left where it is.
@visibleForTesting
void adoptMacOSAppData({
  required List<Directory> supportDirectories,
  required List<Directory> databaseDirectories,
  required Directory takeDatabaseFrom,
  required Directory destination,
}) {
  destination.createSync(recursive: true);

  for (final source in supportDirectories) {
    copyAppDataInto(source, destination);
  }

  for (final source in databaseDirectories) {
    if (!adoptDatabase(source, destination)) continue;
    if (source.path == takeDatabaseFrom.path) _removeDatabase(source);
    return;
  }
}

/// Copies `<name>.sqlite` and its write-ahead log out of [from] into [to].
///
/// Returns whether a database was adopted — false when [from] has none, and
/// false when [to] already has one, which is what makes this idempotent.
///
/// The `-shm` file is deliberately left behind. It is a shared-memory index
/// SQLite rebuilds from the log on the next open, and a copy of it is the one
/// piece of the set that can be stale against the other two.
@visibleForTesting
bool adoptDatabase(Directory from, Directory to) {
  final destination = File('${to.path}/$_databaseName.sqlite');
  if (destination.existsSync()) return false;

  final source = File('${from.path}/$_databaseName.sqlite');
  if (!source.existsSync()) return false;

  to.createSync(recursive: true);
  source.copySync(destination.path);
  final log = File('${from.path}/$_databaseName.sqlite-wal');
  if (log.existsSync()) log.copySync('${destination.path}-wal');
  return true;
}

void _removeDatabase(Directory from) {
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File('${from.path}/$_databaseName.sqlite$suffix');
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Leaving one behind is untidy, never harmful: the copy is already made
      // and nothing reads this path again.
    }
  }
}

/// Recursively copies the contents of [from] into [to], creating [to] as needed.
///
/// An entry that already exists at the destination wins: the app may have
/// written defaults there before this ran, and those are the newer truth.
@visibleForTesting
void copyAppDataInto(Directory from, Directory to) {
  if (!from.existsSync()) return;
  to.createSync(recursive: true);

  for (final entity in from.listSync(followLinks: false)) {
    final name = entity.path.split('/').last;
    final target = '${to.path}/$name';

    if (entity is Directory) {
      copyAppDataInto(entity, Directory(target));
    } else if (entity is File) {
      if (File(target).existsSync() || Directory(target).existsSync()) continue;
      try {
        entity.copySync(target);
      } catch (_) {
        // One unreadable file must not abandon the rest of the tree.
      }
    }
  }
}
