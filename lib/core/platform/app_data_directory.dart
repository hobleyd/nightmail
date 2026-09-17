import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The directory [appDataDirectory] names inside the user's home on macOS.
const String macOSAppDataDirectoryName = '.nightmail';

/// The one directory NightMail stores anything in on this machine.
///
/// **macOS: `~/.nightmail`.** Everything — settings, window bounds, spam rules,
/// the encrypted mail cache — lives in that one directory rather than being
/// spread across whatever `path_provider` happens to resolve.
///
/// It has to be named here because the platform default moves under the app.
/// The macOS release build used to be sandboxed, so every path resolved inside
/// `~/Library/Containers/au.com.sharpblue.nightmail/Data`; taking the sandbox
/// away (which the in-app updater requires — see
/// `macos/Runner/Release.entitlements`) makes the same calls resolve outside it,
/// and `getApplicationDocumentsDirectory()` in particular becomes the user's own
/// **`~/Documents`** — a multi-megabyte mail cache dropped in among their files,
/// on a folder that is iCloud Drive by default. One directory the app names
/// itself cannot drift like that again.
///
/// [migrateMacOSAppData] brings the contents of every previous location here.
///
/// **The redirect is triggered by the platform's own answer, not by the
/// platform.** `getApplicationSupportDirectory()` is resolved first and only
/// rewritten when it came back somewhere under `~/Library` — which is the real
/// macOS answer, sandboxed (`Library/Containers/…`) or not. A test that fakes
/// `PathProviderPlatform` gets a temp directory, that test does not match, and
/// its path is honoured. Redirecting on `Platform.isMacOS` alone instead made
/// every test that writes through this reach into the developer's real home
/// directory, which `spam_filter_repository_impl_test` caught by leaking state
/// between two runs of the same test.
///
/// Every other platform keeps `getApplicationSupportDirectory()`: on Windows and
/// Linux it already resolves somewhere private and conventional, and moving it
/// would mean migrating those installs for no gain. Android and iOS have no home
/// directory in this sense at all.
Future<Directory> appDataDirectory() async {
  final support = await getApplicationSupportDirectory();
  if (kIsWeb || !Platform.isMacOS) return support;

  final redirected = macOSAppDataPathFor(
    supportPath: support.path,
    home: Platform.environment['HOME'],
  );
  if (redirected == null) return support;

  final directory = Directory(redirected);
  if (!directory.existsSync()) directory.createSync(recursive: true);
  return directory;
}

/// Where [appDataDirectory] sends a macOS build whose support directory came
/// back as [supportPath], or null to leave it where the platform put it.
///
/// Separated out so the decision can be tested without a directory being made
/// in whoever is running the tests' home.
@visibleForTesting
String? macOSAppDataPathFor({
  required String supportPath,
  required String? home,
}) {
  if (home == null || home.isEmpty) return null;
  if (!supportPath.startsWith('$home/Library/')) return null;
  return '$home/$macOSAppDataDirectoryName';
}
