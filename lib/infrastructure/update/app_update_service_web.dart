import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import 'app_update_status.dart';

/// [AppUpdateService] for the web build, imported in its place by
/// `injection_container.dart` and `UpdateCubit`. A browser loads whatever the
/// server serves, so there is nothing to update; and `desktop_updater` cannot
/// be compiled for the web (dart2js rejects its 64-bit integer literals), so
/// the real service must not be imported there at all.
///
/// Always [AppUpdatePhase.unsupported], with the running version for the
/// About panel, as the real service reports on a platform without an updater.
class AppUpdateService {
  final _controller = StreamController<AppUpdateStatus>.broadcast();

  AppUpdateStatus _status = const AppUpdateStatus.unsupported();
  bool _started = false;

  AppUpdateStatus get status => _status;
  Stream<AppUpdateStatus> get changes => _controller.stream;
  bool get isSupported => false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _status = _status.copyWith(
        installedVersion: '${info.version}+${info.buildNumber}',
        phase: AppUpdatePhase.unsupported,
      );
      if (!_controller.isClosed) _controller.add(_status);
    } catch (_) {
      // A missing version only leaves the About panel without one.
    }
  }

  Future<void> checkForUpdate() async {}
  Future<void> downloadUpdate() async {}
  Future<void> openFreshInstallDownload() async {}
  Future<void> installUpdate() async {}
  Future<void> openHelperApprovalSettings() async {}
  Future<void> clearPendingInstall() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}
