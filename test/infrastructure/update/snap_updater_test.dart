import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/snap_updater.dart';
import 'package:version/version.dart';

/// Answers the releases API with [release] and every other GET with [bytes].
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.release, required this.bytes});

  final Map<String, dynamic> release;
  final List<int> bytes;
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    if (options.uri.host == 'api.github.com') {
      return ResponseBody.fromString(
        jsonEncode(release),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(bytes),
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
        Headers.contentTypeHeader: ['application/octet-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _release({
  String tag = '1.31.0',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'assets': assets ??
          [
            {
              'name': 'nightmail-1.31.0-release.apk',
              'browser_download_url': 'https://example.test/nightmail.apk',
            },
            {
              'name': 'nightmail_1.31.0_amd64.snap',
              'browser_download_url': 'https://example.test/nightmail.snap',
              'digest': 'sha256:${sha256.convert(_snapBytes)}',
            },
          ],
    };

final _snapBytes = List<int>.generate(4096, (i) => (i * 7) % 251);

SnapUpdater _updater({
  required _FakeAdapter adapter,
  Directory? downloadDir,
  String installed = '1.30.4',
  RunProcess? run,
  StartDetached? detached,
  Map<String, String>? environment,
  void Function(int)? exitProcess,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SnapUpdater(
    dio: dio,
    runProcess: run ??
        (exe, args) async => ProcessResult(1, 0, '', ''),
    startDetached: detached ?? (exe, args, env) async {},
    downloadDirectory: () async =>
        downloadDir ?? Directory.systemTemp.createTempSync('snap_updater'),
    installedVersion: () async => installed,
    environment: environment ?? const {},
    exitProcess: exitProcess ?? (_) {},
  );
}

void main() {
  group('where a snap install is possible', () {
    test('only inside the snap, on Linux', () {
      expect(
        SnapUpdater.isSnapEnvironment({'SNAP_NAME': 'nightmail'},
            isLinux: true),
        isTrue,
      );
      expect(
        SnapUpdater.isSnapEnvironment({'SNAP_NAME': 'nightmail'},
            isLinux: false),
        isFalse,
        reason: 'SNAP_NAME set by hand on another OS is not a snap',
      );
      expect(
        SnapUpdater.isSnapEnvironment({'SNAP_NAME': 'other'}, isLinux: true),
        isFalse,
      );
      expect(SnapUpdater.isSnapEnvironment({}, isLinux: true), isFalse,
          reason: 'a flutter run or plain bundle has nothing snapd can '
              'install over');
    });
  });

  group('check', () {
    test('finds the .snap asset, its digest and the tag', () async {
      final adapter = _FakeAdapter(release: _release(), bytes: _snapBytes);
      final check = await _updater(adapter: adapter).check();

      expect(check, isNotNull);
      expect(check!.fileName, 'nightmail_1.31.0_amd64.snap');
      expect(check.downloadUrl, 'https://example.test/nightmail.snap');
      expect(check.releaseVersion, Version.parse('1.31.0'));
      expect(check.installedVersion, Version.parse('1.30.4'));
      expect(check.sha256, sha256.convert(_snapBytes).toString());
      expect(check.hasUpdate, isTrue);
    });

    test('a release at the running version is not an update', () async {
      final adapter = _FakeAdapter(release: _release(), bytes: _snapBytes);
      final check =
          await _updater(adapter: adapter, installed: '1.31.0').check();
      expect(check!.hasUpdate, isFalse);
    });

    test('a release with no .snap is not an update', () async {
      final adapter = _FakeAdapter(
        release: _release(assets: [
          {
            'name': 'nightmail-1.31.0-release.apk',
            'browser_download_url': 'https://example.test/nightmail.apk',
          },
        ]),
        bytes: _snapBytes,
      );
      expect(await _updater(adapter: adapter).check(), isNull);
    });

    test('a leading v on the tag is tolerated', () async {
      final adapter =
          _FakeAdapter(release: _release(tag: 'v1.31.0'), bytes: _snapBytes);
      final check = await _updater(adapter: adapter).check();
      expect(check!.releaseVersion, Version.parse('1.31.0'));
    });

    test('only a well-formed sha256 digest is kept', () {
      final hex = sha256.convert([1, 2, 3]).toString();
      expect(SnapUpdater.parseSha256Digest('sha256:$hex'), hex);
      expect(SnapUpdater.parseSha256Digest('SHA256:${hex.toUpperCase()}'), hex);
      expect(SnapUpdater.parseSha256Digest('md5:abc'), isNull);
      expect(SnapUpdater.parseSha256Digest('sha256:not-hex'), isNull);
      expect(SnapUpdater.parseSha256Digest(null), isNull);
    });
  });

  group('download', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('snap_updater'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes the file, reports progress and verifies the digest',
        () async {
      final adapter = _FakeAdapter(release: _release(), bytes: _snapBytes);
      final updater = _updater(adapter: adapter, downloadDir: dir);
      final check = (await updater.check())!;

      final progress = <(int, int)>[];
      final file = await updater.download(
        check,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(file.path, endsWith('nightmail_1.31.0_amd64.snap'));
      expect(await file.readAsBytes(), _snapBytes);
      expect(progress, isNotEmpty);
      expect(progress.last.$1, _snapBytes.length);
      expect(progress.last.$2, _snapBytes.length);
    });

    test('a digest mismatch discards the file and says so', () async {
      final adapter = _FakeAdapter(
        release: _release(),
        // Different bytes from the ones the digest was computed over.
        bytes: List<int>.filled(4096, 0),
      );
      final updater = _updater(adapter: adapter, downloadDir: dir);
      final check = (await updater.check())!;

      await expectLater(
        updater.download(check),
        throwsA(isA<SnapInstallException>().having(
          (e) => e.message,
          'message',
          contains('checksum'),
        )),
      );
      expect(dir.listSync(), isEmpty,
          reason: 'a file that failed verification must never reach '
              'snap install');
    });

    test('a release with no digest is downloaded unverified', () async {
      final adapter = _FakeAdapter(
        release: _release(assets: [
          {
            'name': 'nightmail_1.31.0_amd64.snap',
            'browser_download_url': 'https://example.test/nightmail.snap',
          },
        ]),
        bytes: _snapBytes,
      );
      final updater = _updater(adapter: adapter, downloadDir: dir);
      final check = (await updater.check())!;
      expect(check.sha256, isNull);
      final file = await updater.download(check);
      expect(await file.exists(), isTrue);
    });

    test('clears what an earlier download left behind', () async {
      File('${dir.path}/nightmail_1.30.9_amd64.snap').writeAsStringSync('old');
      final adapter = _FakeAdapter(release: _release(), bytes: _snapBytes);
      final updater = _updater(adapter: adapter, downloadDir: dir);
      await updater.download((await updater.check())!);

      expect(
        dir.listSync().map((e) => e.uri.pathSegments.last),
        ['nightmail_1.31.0_amd64.snap'],
      );
    });
  });

  group('install', () {
    test('sideloads over the running revision, ignoring that it is running',
        () {
      expect(
        SnapUpdater.installArguments(File('/home/u/.nightmail/updates/x.snap')),
        [
          'install',
          '--dangerous',
          '--classic',
          '--ignore-running',
          '/home/u/.nightmail/updates/x.snap',
        ],
      );
    });

    test('runs snap with those arguments and is quiet on success', () async {
      String? exe;
      List<String>? args;
      final updater = _updater(
        adapter: _FakeAdapter(release: _release(), bytes: _snapBytes),
        run: (e, a) async {
          exe = e;
          args = a;
          return ProcessResult(1, 0, 'nightmail 1.31.0 installed', '');
        },
      );
      await updater.install(File('/tmp/x.snap'));
      expect(exe, 'snap');
      expect(args, SnapUpdater.installArguments(File('/tmp/x.snap')));
    });

    test('a refused or cancelled password prompt reads as one', () async {
      final updater = _updater(
        adapter: _FakeAdapter(release: _release(), bytes: _snapBytes),
        run: (e, a) async =>
            ProcessResult(1, 1, '', 'error: access denied (try with sudo)'),
      );
      await expectLater(
        updater.install(File('/tmp/x.snap')),
        throwsA(isA<SnapInstallException>().having(
          (e) => e.message,
          'message',
          allOf(contains('password'), contains('Restart and install')),
        )),
      );
    });

    test("any other failure carries snapd's own first line", () {
      expect(
        SnapUpdater.describeInstallFailure(
          exitCode: 1,
          stderr: 'error: cannot install "x.snap": classic confinement '
              'requires snaps under /snap\n',
          stdout: '',
        ),
        'snap install failed: cannot install "x.snap": classic confinement '
        'requires snaps under /snap',
      );
      expect(
        SnapUpdater.describeInstallFailure(exitCode: 7, stderr: '', stdout: ''),
        'snap install failed with exit code 7.',
      );
    });
  });

  group('relaunch', () {
    test('waits for this process to exit, then starts the launcher', () {
      final args =
          SnapUpdater.relaunchArguments(pid: 4242, launcher: '/snap/bin/nightmail');
      expect(args.first, '-c');
      expect(args[1], contains('kill -0 "\$1"'),
          reason: 'the new revision must not start beside the running one');
      expect(args[1], contains('exec \$2'));
      expect(args.sublist(2), ['sh', '4242', '/snap/bin/nightmail']);
    });

    test("scrubs the departing revision's snap runtime from the environment",
        () {
      final env = SnapUpdater.relaunchEnvironment({
        'SNAP': '/snap/nightmail/12',
        'SNAP_NAME': 'nightmail',
        'SNAP_REVISION': '12',
        'SNAP_USER_DATA': '/home/u/snap/nightmail/12',
        'HOME': '/home/u',
        'DISPLAY': ':0',
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/run/user/1000/bus',
      });
      expect(env.keys.where((k) => k.startsWith('SNAP')), isEmpty);
      expect(env['HOME'], '/home/u');
      expect(env['DISPLAY'], ':0');
      expect(env['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=/run/user/1000/bus');
    });

    test('starts the helper detached and then exits this process', () async {
      final started = <(String, List<String>, Map<String, String>)>[];
      final exits = <int>[];
      final updater = _updater(
        adapter: _FakeAdapter(release: _release(), bytes: _snapBytes),
        detached: (exe, args, env) async => started.add((exe, args, env)),
        environment: {'SNAP_NAME': 'nightmail', 'HOME': '/home/u'},
        exitProcess: exits.add,
      );

      await updater.relaunch(processId: 99);

      expect(started, hasLength(1));
      expect(started.single.$1, 'sh');
      expect(started.single.$2[3], '99');
      expect(started.single.$3, {'HOME': '/home/u'});
      expect(exits, [0], reason: 'the helper is waiting on this pid');
    });
  });
}
