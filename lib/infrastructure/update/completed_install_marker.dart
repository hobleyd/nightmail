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
