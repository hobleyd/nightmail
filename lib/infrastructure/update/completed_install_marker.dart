import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The prefix `desktop_updater` gives every staging directory it creates.
const String kDesktopUpdaterStagePrefix = 'desktop_updater_stage_';

/// Clears the pending-install marker a *completed* macOS install leaves
/// behind, which `desktop_updater` cannot clear itself and which, since 3.2.1,
/// refuses every later install.
///
/// After a successful install the helper has renamed the staged bundle into
/// `/Applications`, so the stage directory holds only the artifact zip, the
/// release manifest and the provenance file. The package's recovery pass
/// confirms the installed version matches the marker, then insists on deleting
/// the stage before it will clear the marker — and that deletion re-verifies
/// the stage's recorded inventory, bundle included, which can never match
/// again. So every launch logs "Completed install stage cleanup failed." and
/// keeps the marker, and the next install is refused with "A pending install
/// must be recovered before another install" (2026-10-12: 1.39.3 installed,
/// 1.39.4 refused). 3.1.6 leaked the same way but overwrote the marker.
///
/// This runs before the package's recovery pass and acts only when the
/// marker's target *is* the running version — the package's own test for a
/// completed install — and the staged bundle is gone. The only thing it
/// deletes is a stage directory the package named, `desktop_updater_stage_…`,
/// which is a downloaded copy and nothing else, and then the marker. A stage
/// that still holds its bundle, a marker for another version, another
/// platform's marker and a marker that will not parse are all left for the
/// package to handle and report.
///
/// Returns true when the marker was cleared.
Future<bool> clearCompletedInstallMarker({
  required File marker,
  required String installedVersion,
  required String installedBuildNumber,
  void Function(String)? log,
}) async {
  if (!await marker.exists()) return false;

  final Object? decoded;
  try {
    decoded = jsonDecode(await marker.readAsString());
  } on FormatException {
    return false;
  }
  if (decoded is! Map<String, dynamic>) return false;
  if (decoded['platform'] != 'macos') return false;
  if (decoded['updateVersion'] != installedVersion) return false;
  if ('${decoded['updateBuildNumber']}' != installedBuildNumber) return false;

  final stagingPath = decoded['stagingPath'];
  if (stagingPath is! String || stagingPath.isEmpty) return false;
  if (await FileSystemEntity.type(stagingPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }

  final stageRoot = Directory(stagingPath).parent;
  final stageName = stageRoot.path
      .substring(stageRoot.path.lastIndexOf(Platform.pathSeparator) + 1);
  if (!stageName.startsWith(kDesktopUpdaterStagePrefix)) return false;

  if (await stageRoot.exists()) {
    await stageRoot.delete(recursive: true);
  }
  await marker.delete();
  (log ?? debugPrint)('[Update] $installedVersion+$installedBuildNumber is installed and its '
      'stage was consumed, which desktop_updater cannot clear — removed '
      '${stageRoot.path} and the pending-install marker');
  return true;
}

/// The user-pressed version of [clearCompletedInstallMarker]: throws the
/// pending install away whatever state it is in, for Settings → About's
/// "Clear pending install…" button.
///
/// [clearCompletedInstallMarker] only covers an install that *succeeded*. An
/// attempt that failed part-way leaves the same marker for a version that was
/// never installed — 2026-10-30, 1.41.1 over 1.41.0: the handoff came back
/// "Administrator approval is required", and every press of Restart and
/// install after that was refused with "A pending install must be recovered
/// before another install". The package re-reads the marker before each
/// install, so removing it is what unblocks the next one; nothing in it is
/// data, and the stage is a downloaded copy the app fetches again.
///
/// Deletes the marker's stage directory only when it carries the package's
/// own `desktop_updater_stage_…` name, then the marker itself — including one
/// that will not parse, since a torn marker blocks installs just the same.
///
/// Returns true when a marker was removed.
Future<bool> clearPendingInstallMarker({
  required File marker,
  void Function(String)? log,
}) async {
  if (!await marker.exists()) return false;

  String? stagingPath;
  try {
    final decoded = jsonDecode(await marker.readAsString());
    if (decoded is Map<String, dynamic> && decoded['stagingPath'] is String) {
      stagingPath = decoded['stagingPath'] as String;
    }
  } on FormatException {
    // Removed below all the same.
  }

  String? removedStage;
  if (stagingPath != null && stagingPath.isNotEmpty) {
    final stageRoot = Directory(stagingPath).parent;
    final stageName = stageRoot.path
        .substring(stageRoot.path.lastIndexOf(Platform.pathSeparator) + 1);
    if (stageName.startsWith(kDesktopUpdaterStagePrefix) &&
        await stageRoot.exists()) {
      await stageRoot.delete(recursive: true);
      removedStage = stageRoot.path;
    }
  }
  await marker.delete();
  (log ?? debugPrint)('[Update] cleared the pending install at the user\'s '
      'request — removed ${removedStage ?? 'no stage'} and the marker');
  return true;
}
