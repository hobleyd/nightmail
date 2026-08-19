import 'dart:io';

import 'package:android_package_installer/android_package_installer.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:version/version.dart';

/// The APK the newest GitHub release offers, and how it compares to this build.
class AndroidReleaseCheck {
  const AndroidReleaseCheck({
    required this.installedVersion,
    required this.releaseVersion,
    required this.downloadUrl,
    required this.fileName,
  });

  final Version installedVersion;
  final Version releaseVersion;
  final String downloadUrl;
  final String fileName;

  bool get hasUpdate => releaseVersion > installedVersion;
}

/// Android's half of in-app updates: the newest GitHub release's APK, handed to
/// the system package installer.
///
/// Android cannot use `desktop_updater` — there is no directory to swap and no
/// restart helper; an APK has to go through `PackageInstaller`, which shows its
/// own confirmation UI and replaces the process itself. So this is the whole
/// mechanism, and it is deliberately the same one `../inkworm` uses.
///
/// **The comparison is on the semver part alone.** The release workflow tags
/// with the version stripped of its build number (`1.20.0`, not `1.20.0+17`) and
/// moves that tag, so a rebuild at the same pubspec version is invisible here —
/// whereas the desktop path compares version *and* build number out of the
/// signed app-archive. Bumping `pubspec.yaml` is what publishes an update to
/// Android. Same behaviour as inkworm; not a bug to be fixed here.
class AndroidApkUpdater {
  AndroidApkUpdater({
    Dio? dio,
    this.releasesApiUrl =
        'https://api.github.com/repos/hobleyd/nightmail/releases/latest',
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 20),
              ),
            );

  final Dio _dio;
  final String releasesApiUrl;

  /// Reads the newest release. Returns null when it carries no APK — a release
  /// whose Android job failed still exists, and is not an update.
  Future<AndroidReleaseCheck?> check() async {
    final response = await _dio.get<Map<String, dynamic>>(releasesApiUrl);
    final data = response.data;
    if (response.statusCode != 200 || data == null) return null;

    final assets = data['assets'];
    if (assets is! List) return null;

    Map<String, dynamic>? apk;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      if (name is String && name.toLowerCase().endsWith('.apk')) {
        apk = Map<String, dynamic>.from(asset);
        break;
      }
    }
    if (apk == null) return null;

    final url = apk['browser_download_url'];
    final fileName = apk['name'];
    final tag = data['tag_name'];
    if (url is! String || fileName is! String || tag is! String) return null;

    final info = await PackageInfo.fromPlatform();

    return AndroidReleaseCheck(
      installedVersion: Version.parse(info.version),
      releaseVersion: Version.parse(tag.startsWith('v') ? tag.substring(1) : tag),
      downloadUrl: url,
      fileName: fileName,
    );
  }

  /// Downloads [check]'s APK into the app's cache directory and hands it to the
  /// system installer.
  ///
  /// The cache directory — not external storage — is what `file_paths.xml`'s
  /// `cache-path` entry grants the `FileProvider` access to, so no storage
  /// permission is involved. Throws [AndroidInstallException] when the installer
  /// reports anything other than success; a user who dismisses the system
  /// confirmation lands here too, which is why the message is shown rather than
  /// treated as a fault.
  Future<void> downloadAndInstall(
    AndroidReleaseCheck check, {
    void Function(int received, int total)? onProgress,
  }) async {
    final cacheDir = await getTemporaryDirectory();
    final apkPath = '${cacheDir.path}${Platform.pathSeparator}${check.fileName}';

    await _dio.download(
      check.downloadUrl,
      apkPath,
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        onProgress?.call(received, total);
      },
    );

    final statusCode =
        await AndroidPackageInstaller.installApk(apkFilePath: apkPath);
    if (statusCode == null) {
      throw const AndroidInstallException(
        'Android did not return an installation result.',
      );
    }

    final status = PackageInstallerStatus.byCode(statusCode);
    if (status != PackageInstallerStatus.success) {
      throw AndroidInstallException('Install failed: ${status.name}.');
    }
  }
}

class AndroidInstallException implements Exception {
  const AndroidInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}
