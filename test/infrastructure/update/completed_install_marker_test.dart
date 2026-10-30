import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/completed_install_marker.dart';

/// A completed macOS install leaves a stage whose bundle the helper has
/// consumed and a marker `desktop_updater` can then never clear; 3.2.1 refuses
/// every later install while that marker exists. These pin the one case the
/// app clears itself, and every neighbouring case it leaves to the package.
void main() {
  late Directory root;
  late Directory stageRoot;
  late File marker;
  late List<String> logged;

  const nonce = 'ab652036-d834-46b5-88dc-9b43e07d73d2';

  Future<void> writeMarker({
    String platform = 'macos',
    String version = '1.39.3',
    Object? build = 221,
    String? stagingPath,
  }) async {
    await marker.writeAsString(jsonEncode({
      'createdAt': '2026-10-12T05:09:29.392500Z',
      'packageVersion': '3.1.6',
      'platform': platform,
      'channel': 'stable',
      'appVersion': '1.39.2+220',
      'updateVersion': version,
      'updateBuildNumber': build,
      'expectedPackageId': 'au.com.sharpblue.nightmail',
      'stagingPath': stagingPath ?? '${stageRoot.path}/NightMail.app',
      'stageProvenanceSha256': 'c482fabcd44388d8603202e5cc2dd86ace743866a',
      'diagnosticsText': 'Update Problem Report',
      'transactionId': 'd5145d1e-3bb4-41c6-9b98-3a0f604c125e',
    }));
  }

  /// What the helper leaves behind after it has renamed the bundle away.
  Future<void> writeConsumedStage() async {
    await stageRoot.create(recursive: true);
    for (final name in const [
      '.desktop_updater_artifact.zip',
      '.desktop_updater_release_manifest.json',
      '.desktop_updater_stage_provenance.json',
    ]) {
      await File('${stageRoot.path}/$name').writeAsString('x');
    }
  }

  Future<bool> run({String version = '1.39.3', String build = '221'}) =>
      clearCompletedInstallMarker(
        marker: marker,
        installedVersion: version,
        installedBuildNumber: build,
        log: logged.add,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nightmail-marker-');
    stageRoot = Directory('${root.path}/$kDesktopUpdaterStagePrefix$nonce');
    marker = File('${root.path}/desktop_updater_pending_install.json');
    logged = [];
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a completed install whose bundle was consumed: stage and marker go',
      () async {
    await writeConsumedStage();
    await writeMarker();

    expect(await run(), isTrue);
    expect(await marker.exists(), isFalse);
    expect(await stageRoot.exists(), isFalse);
    expect(logged, hasLength(1));
    expect(logged.single, startsWith('[Update] 1.39.3+221 is installed'));
    expect(logged.single, contains(stageRoot.path));
  });

  test('the stage already gone: the marker still goes', () async {
    await writeMarker();

    expect(await run(), isTrue);
    expect(await marker.exists(), isFalse);
  });

  test('a stage that still holds its bundle is left for the package',
      () async {
    await writeConsumedStage();
    await Directory('${stageRoot.path}/NightMail.app').create();
    await writeMarker();

    expect(await run(), isFalse);
    expect(await marker.exists(), isTrue);
    expect(await stageRoot.exists(), isTrue);
    expect(logged, isEmpty);
  });

  test('a marker for a version that is not the one running is left alone',
      () async {
    await writeConsumedStage();
    await writeMarker();

    expect(await run(version: '1.39.4', build: '222'), isFalse,
        reason: 'an install that did not complete is the package\'s to '
            'recover or report');
    expect(await run(build: '220'), isFalse,
        reason: 'the build number is the whole of the desktop comparison');
    expect(await marker.exists(), isTrue);
    expect(await stageRoot.exists(), isTrue);
  });

  test('a directory the package did not name is never deleted', () async {
    final other = Directory('${root.path}/Documents');
    await other.create();
    await File('${other.path}/keep.txt').writeAsString('precious');
    await writeMarker(stagingPath: '${other.path}/NightMail.app');

    expect(await run(), isFalse);
    expect(await File('${other.path}/keep.txt').exists(), isTrue);
    expect(await marker.exists(), isTrue);
  });

  test('another platform\'s marker is left to the package', () async {
    await writeConsumedStage();
    await writeMarker(platform: 'windows');

    expect(await run(), isFalse);
    expect(await marker.exists(), isTrue);
  });

  test('a marker that will not parse is left for the package to report',
      () async {
    await marker.writeAsString('{"createdAt": "2026-10-12T05:09');

    expect(await run(), isFalse);
    expect(await marker.exists(), isTrue);
  });

  test('no marker: nothing happens', () async {
    expect(await run(), isFalse);
    expect(logged, isEmpty);
  });

  group('clearing it on request', () {
    Future<bool> clear() =>
        clearPendingInstallMarker(marker: marker, log: logged.add);

    test('a failed attempt\'s marker and stage are both removed', () async {
      // 2026-10-30: the handoff for 1.41.1 failed, so the bundle is still in
      // the stage and the marker names a version that never installed —
      // exactly what clearCompletedInstallMarker leaves alone.
      await writeConsumedStage();
      await Directory('${stageRoot.path}/NightMail.app').create();
      await writeMarker(version: '1.41.1', build: 245);

      expect(await clear(), isTrue);
      expect(await marker.exists(), isFalse);
      expect(await stageRoot.exists(), isFalse);
      expect(logged.single, contains(stageRoot.path));
    });

    test('a directory the package did not name is never deleted', () async {
      final other = Directory('${root.path}/Documents');
      await other.create();
      await File('${other.path}/keep.txt').writeAsString('precious');
      await writeMarker(stagingPath: '${other.path}/NightMail.app');

      expect(await clear(), isTrue);
      expect(await File('${other.path}/keep.txt').exists(), isTrue);
      expect(await marker.exists(), isFalse);
    });

    test('a torn marker is removed too, since it blocks installs the same',
        () async {
      await marker.writeAsString('{"createdAt": "2026-10-12T05:09');

      expect(await clear(), isTrue);
      expect(await marker.exists(), isFalse);
    });

    test('no marker: nothing happens', () async {
      expect(await clear(), isFalse);
      expect(logged, isEmpty);
    });
  });
}
