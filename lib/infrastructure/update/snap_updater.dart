import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:version/version.dart';

import '../../core/platform/app_data_directory.dart';

/// The snap the newest GitHub release offers, and how it compares to this build.
class SnapReleaseCheck {
  const SnapReleaseCheck({
    required this.installedVersion,
    required this.releaseVersion,
    required this.downloadUrl,
    required this.fileName,
    this.sha256,
  });

  final Version installedVersion;
  final Version releaseVersion;
  final String downloadUrl;
  final String fileName;

  /// Lower-case hex SHA-256 of the asset, when the release API published one
  /// (`digest: "sha256:…"`). Null for releases made before GitHub recorded it.
  final String? sha256;

  bool get hasUpdate => releaseVersion > installedVersion;
}

/// Runs a command to completion. Injected so tests never reach `snap`.
typedef RunProcess = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Starts a process that must outlive this one. Injected for the same reason.
typedef StartDetached = Future<void> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// Linux's half of in-app updates: the newest GitHub release's `.snap`,
/// installed by snapd from the downloaded file, then the app relaunched.
///
/// The snap is sideloaded — installed from the release asset with
/// `--dangerous`, never from the Snap Store — so snapd will not refresh it on
/// its own, and the store's auto-refresh, delta downloads and signature checks
/// are all unavailable. This is what stands in for them:
///
/// - **Which release is newest** comes from the GitHub releases API, exactly as
///   on Android: the tag stripped of its build number, compared as a semver
///   against the running `PackageInfo.version`. Bumping `pubspec.yaml` is what
///   publishes an update; a re-push at the same version is invisible here.
/// - **Integrity** is the release asset's SHA-256 `digest`, checked after the
///   download when the API supplied one. That is weaker than the desktop
///   path's signed archive — it trusts GitHub over TLS rather than a pinned
///   key — and it is the same trust Android already places in the APK.
/// - **Installing** is `snap install --dangerous --classic --ignore-running`,
///   run as the user. snapd authorises that through polkit
///   (`io.snapcraft.snapd.manage`, `auth_admin_keep` for an active session), so
///   the desktop asks for the password; no `sudo`, no helper of our own.
///   `--ignore-running` is required: a sideload of an installed snap is a
///   refresh, and snapd refuses a manual refresh of a snap with running apps —
///   which this app, by definition, is.
/// - **Relaunching** cannot be done by starting the new revision beside the
///   old one, so [relaunch] leaves a detached shell waiting for this process to
///   exit and then starting `/snap/bin/nightmail`, and exits. The helper's
///   environment is scrubbed of `SNAP*`: it inherits this revision's snap
///   runtime, and `snap run` has to compute the new one from scratch.
///
/// Only meaningful inside the snap ([isRunningInSnap]). A Linux build run from
/// `flutter run` or a plain bundle has nothing snapd could install over, and
/// `AppUpdateService` reports it unsupported.
class SnapUpdater {
  SnapUpdater({
    Dio? dio,
    this.releasesApiUrl =
        'https://api.github.com/repos/hobleyd/nightmail/releases/latest',
    RunProcess? runProcess,
    StartDetached? startDetached,
    Future<Directory> Function()? downloadDirectory,
    Future<String> Function()? installedVersion,
    Map<String, String>? environment,
    void Function(int code)? exitProcess,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
              ),
            ),
        _runProcess = runProcess ?? Process.run,
        _startDetached = startDetached ?? _startDetachedProcess,
        _downloadDirectory = downloadDirectory ?? _defaultDownloadDirectory,
        _installedVersion = installedVersion ?? _packageVersion,
        _environment = environment ?? Platform.environment,
        _exit = exitProcess ?? exit;

  final Dio _dio;
  final String releasesApiUrl;
  final RunProcess _runProcess;
  final StartDetached _startDetached;
  final Future<Directory> Function() _downloadDirectory;
  final Future<String> Function() _installedVersion;
  final Map<String, String> _environment;
  final void Function(int code) _exit;

  /// The snap's name in `snap/snapcraft.yaml`, which is also what snapd puts in
  /// `SNAP_NAME` for every process it launches from it.
  static const String snapName = 'nightmail';

  /// The launcher snapd installs for the snap's app. Preferred over `snap run`
  /// because it is what the desktop entry runs, so the relaunch and a click in
  /// the dock produce the same process.
  static const String launcherPath = '/snap/bin/$snapName';

  /// Whether this process was started by snapd from the NightMail snap.
  static bool get isRunningInSnap =>
      isSnapEnvironment(Platform.environment, isLinux: Platform.isLinux);

  @visibleForTesting
  static bool isSnapEnvironment(
    Map<String, String> environment, {
    required bool isLinux,
  }) =>
      isLinux && environment['SNAP_NAME'] == snapName;

  /// Reads the newest release. Returns null when it carries no `.snap` — a
  /// release whose Linux job failed still exists, and is not an update.
  Future<SnapReleaseCheck?> check() async {
    final response = await _dio.get<Map<String, dynamic>>(releasesApiUrl);
    final data = response.data;
    if (response.statusCode != 200 || data == null) return null;

    final assets = data['assets'];
    if (assets is! List) return null;

    Map<String, dynamic>? snap;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      if (name is String && name.toLowerCase().endsWith('.snap')) {
        snap = Map<String, dynamic>.from(asset);
        break;
      }
    }
    if (snap == null) return null;

    final url = snap['browser_download_url'];
    final fileName = snap['name'];
    final tag = data['tag_name'];
    if (url is! String || fileName is! String || tag is! String) return null;

    return SnapReleaseCheck(
      installedVersion: Version.parse(await _installedVersion()),
      releaseVersion:
          Version.parse(tag.startsWith('v') ? tag.substring(1) : tag),
      downloadUrl: url,
      fileName: fileName,
      sha256: parseSha256Digest(snap['digest']),
    );
  }

  /// `sha256:<hex>` as GitHub publishes it, or null for anything else.
  @visibleForTesting
  static String? parseSha256Digest(Object? digest) {
    if (digest is! String) return null;
    const prefix = 'sha256:';
    if (!digest.toLowerCase().startsWith(prefix)) return null;
    final hex = digest.substring(prefix.length).toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }

  /// Downloads [check]'s snap and verifies it against the published digest.
  ///
  /// Anything already in the download directory goes first: a snap is tens of
  /// megabytes and there is never a reason to keep more than the one about to
  /// be installed. A digest mismatch deletes the file and throws, so a
  /// truncated or tampered download is never offered to `snap install`.
  Future<File> download(
    SnapReleaseCheck check, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await _downloadDirectory();
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {}
      }
    }
    await dir.create(recursive: true);

    final file = File('${dir.path}${Platform.pathSeparator}${check.fileName}');
    await _dio.download(
      check.downloadUrl,
      file.path,
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        onProgress?.call(received, total);
      },
    );

    final expected = check.sha256;
    if (expected != null) {
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected) {
        try {
          await file.delete();
        } catch (_) {}
        throw const SnapInstallException(
          'The downloaded update did not match the published checksum, so it '
          'was discarded. Try again.',
        );
      }
    }
    return file;
  }

  /// The command that installs [snap] over the running revision.
  @visibleForTesting
  static List<String> installArguments(File snap) => [
        'install',
        '--dangerous',
        '--classic',
        '--ignore-running',
        snap.path,
      ];

  /// Hands [snap] to snapd. The desktop asks for the user's password on the
  /// way; a refused or cancelled prompt comes back as `access denied`.
  Future<void> install(File snap) async {
    final result = await _runProcess('snap', installArguments(snap));
    if (result.exitCode == 0) return;
    throw SnapInstallException(describeInstallFailure(
      exitCode: result.exitCode,
      stderr: result.stderr.toString(),
      stdout: result.stdout.toString(),
    ));
  }

  /// One readable sentence for a failed `snap install`.
  @visibleForTesting
  static String describeInstallFailure({
    required int exitCode,
    required String stderr,
    required String stdout,
  }) {
    final text = '$stderr\n$stdout';
    if (text.contains('access denied')) {
      return 'NightMail needs your password to install the update, and the '
          'prompt was cancelled or refused. Press Restart and install to try '
          'again.';
    }
    for (final raw in text.split('\n')) {
      var line = raw.trim();
      if (line.startsWith('error:')) line = line.substring(6).trim();
      if (line.isNotEmpty) return 'snap install failed: $line';
    }
    return 'snap install failed with exit code $exitCode.';
  }

  /// The environment the relaunch helper runs with: this process's, minus the
  /// snap runtime it was started under.
  @visibleForTesting
  static Map<String, String> relaunchEnvironment(Map<String, String> env) => {
        for (final entry in env.entries)
          if (!entry.key.startsWith('SNAP')) entry.key: entry.value,
      };

  /// Leaves a helper waiting for this process to exit and then starting the
  /// newly installed revision, and exits. Does not return in the normal case.
  ///
  /// The wait is the point: starting the new revision while this one is still
  /// running would put two NightMails on screen, and snapd's `--ignore-running`
  /// only lets the install proceed — it does nothing about the process it
  /// ignored.
  Future<void> relaunch({int? processId}) async {
    final launcher =
        await File(launcherPath).exists() ? launcherPath : 'snap run $snapName';
    await _startDetached(
      'sh',
      relaunchArguments(pid: processId ?? pid, launcher: launcher),
      relaunchEnvironment(_environment),
    );
    _exit(0);
  }

  @visibleForTesting
  static List<String> relaunchArguments({
    required int pid,
    required String launcher,
  }) =>
      [
        '-c',
        'while kill -0 "\$1" 2>/dev/null; do sleep 0.2; done; exec \$2',
        'sh',
        '$pid',
        launcher,
      ];

  static Future<void> _startDetachedProcess(
    String executable,
    List<String> arguments,
    Map<String, String> environment,
  ) async {
    await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
    );
  }

  /// `~/.nightmail/updates`: the app's own directory (see
  /// `core/platform/app_data_directory.dart`), so the file survives a reboot
  /// between download and install and is never mistaken for the user's.
  static Future<Directory> _defaultDownloadDirectory() async {
    final base = await appDataDirectory();
    return Directory('${base.path}${Platform.pathSeparator}updates');
  }

  static Future<String> _packageVersion() async =>
      (await PackageInfo.fromPlatform()).version;
}

class SnapInstallException implements Exception {
  const SnapInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}
