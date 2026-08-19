import 'dart:async';
import 'dart:io';

import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/platform/window_utils.dart';
import 'android_apk_updater.dart';
import 'app_update_status.dart';
import 'release_notes_fetcher.dart';
import 'update_recovery_store.dart';

/// Where the signed app-archive and the release notes are published. The
/// release workflow's `deploy` job writes both to this GitHub Pages site.
const String kUpdateBaseUrl = 'https://hobleyd.github.io/nightmail/';

/// The signed index of every published release, per platform and channel.
final Uri kAppArchiveUrl = Uri.parse('${kUpdateBaseUrl}app-archive.json');

/// Notes for the newest published release. Regenerated on every deploy.
final Uri kReleaseNotesUrl = Uri.parse('${kUpdateBaseUrl}release-notes.json');

/// Must match `--package-id` in the release workflow's packaging step and the
/// `packageId` bound into each signed release descriptor.
const String kUpdatePackageId = 'au.com.sharpblue.nightmail';

/// Pinned Ed25519 public keys from `desktop_updater.keys.json`.
///
/// Only an app-archive and release descriptor signed by the matching private
/// key — a GitHub Actions secret, never in this repository — are trusted. This
/// is the whole of the update chain's security: an attacker who serves a
/// different archive from the same URL cannot sign it.
const Map<String, String> kTrustedReleasePublicKeys = {
  'release-b53948b0e36b895fa047a8f4':
      'CS5SJb9jMzPxDQZpkLXANll0mu0sFBpyQFny9lp72Qw=',
};

/// Owns in-app updating, and is the one place that knows which mechanism this
/// platform uses.
///
/// | Platform | Mechanism |
/// |---|---|
/// | macOS, Windows | `desktop_updater` — a signed app-archive on GitHub Pages, downloaded, verified, staged, then handed to a native installer |
/// | Android | An APK from the newest GitHub release, handed to the system package installer ([AndroidApkUpdater]) |
/// | Linux | None — NightMail ships as a snap, and snapd updates it |
/// | iOS, web | None |
///
/// **This is constructed and started at launch, not when Settings opens.** The
/// dot on the Settings icon has to be able to appear before the user has gone
/// looking, so `HomePage` calls [start] on the singleton and the About panel
/// merely attaches to the status it is already publishing. That is the one
/// deliberate structural divergence from `../inkworm`, which builds its
/// controller inside the About widget's `initState` and so cannot show a dot at
/// all.
///
/// **Main window only.** `desktop_multi_window` re-enters `main()` with a fresh
/// isolate and service locator per sub-window, so a second engine would run its
/// own recovery pass over the same marker file and could start a second native
/// install handoff concurrently with the first. [AppWindow.isMain] gates the
/// whole thing; in a sub-window every method is a no-op and the status stays
/// [AppUpdatePhase.unsupported].
class AppUpdateService {
  AppUpdateService({
    AndroidApkUpdater? androidUpdater,
    ReleaseNotesFetcher? releaseNotesFetcher,
    @visibleForTesting bool? isSupportedOverride,
  })  : _androidUpdater = androidUpdater ?? AndroidApkUpdater(),
        _releaseNotesFetcher =
            releaseNotesFetcher ?? ReleaseNotesFetcher(url: kReleaseNotesUrl),
        _isSupported = isSupportedOverride ?? _platformIsSupported();

  final AndroidApkUpdater _androidUpdater;
  final ReleaseNotesFetcher _releaseNotesFetcher;
  final bool _isSupported;

  final _controller = StreamController<AppUpdateStatus>.broadcast();

  AppUpdateStatus _status = const AppUpdateStatus();

  /// The current status. Never null; starts [AppUpdatePhase.unsupported] on a
  /// platform without an updater, and [AppUpdatePhase.idle] elsewhere.
  AppUpdateStatus get status => _status;

  /// Emits on every status change. [UpdateCubit] rides on this.
  Stream<AppUpdateStatus> get changes => _controller.stream;

  bool get isSupported => _isSupported;

  /// How often a still-running app looks again. NightMail is left open for
  /// days, so a check only at launch would mean never in practice. It only
  /// *checks* — nothing downloads or installs without the user pressing the
  /// button, which is why this can be quiet and unattended.
  static const _recheckInterval = Duration(hours: 6);

  DesktopUpdaterController? _desktop;
  AndroidReleaseCheck? _androidCheck;
  Timer? _recheckTimer;
  bool _started = false;
  bool _notesRequested = false;

  static bool _platformIsSupported() {
    if (kIsWeb || !AppWindow.isMain) return false;
    // Linux is excluded on purpose: the Linux build is distributed as a snap,
    // which snapd refreshes on its own, and there is no Linux entry in the
    // app-archive for the controller to find — it would sit in a permanent
    // "no update" state and the About panel would be lying about what is
    // managing updates.
    return Platform.isMacOS || Platform.isWindows || Platform.isAndroid;
  }

  /// Reads the running version and starts the first check. Safe to call
  /// repeatedly — `HomePage` calls it on every build, as it does for
  /// [OverdueTasksCubit].
  Future<void> start() async {
    if (_started) return;
    _started = true;

    if (!_isSupported) {
      _emit(const AppUpdateStatus.unsupported());
      // The installed version is still worth showing on an unsupported
      // platform: the About panel prints it whether or not it can update.
      await _loadInstalledVersion(unsupported: true);
      return;
    }

    await _loadInstalledVersion();
    await checkForUpdate();

    // Skipped once an update has been found: there is nothing further to learn
    // until the user acts on it, and re-checking would clear and re-set the
    // status the dot is drawn from.
    _recheckTimer ??= Timer.periodic(_recheckInterval, (_) {
      if (_status.hasActionableUpdate) return;
      unawaited(checkForUpdate());
    });
  }

  Future<void> _loadInstalledVersion({bool unsupported = false}) async {
    try {
      final info = await PackageInfo.fromPlatform();
      _emit(_status.copyWith(
        installedVersion: '${info.version}+${info.buildNumber}',
        phase: unsupported ? AppUpdatePhase.unsupported : null,
      ));
    } catch (_) {
      // A missing platform version is not worth failing an update check over.
    }
  }

  /// Checks for a newer release. Reports the outcome on [changes] rather than
  /// throwing — every caller is a UI that wants to draw the failure.
  Future<void> checkForUpdate() async {
    if (!_isSupported) return;
    if (_status.phase == AppUpdatePhase.downloading ||
        _status.phase == AppUpdatePhase.installing) {
      return;
    }

    _emit(_status.copyWith(
      phase: AppUpdatePhase.checking,
      // Reset explicitly: a download that failed leaves counters behind, and
      // AppUpdateStatus.progress would then report a fraction for a transfer
      // that is no longer happening.
      receivedBytes: 0,
      totalBytes: 0,
      clearError: true,
      clearAvailableVersion: true,
    ));

    try {
      if (Platform.isAndroid) {
        await _checkAndroid();
      } else {
        await _checkDesktop();
      }
    } catch (error) {
      _emit(_status.copyWith(
        phase: AppUpdatePhase.failed,
        error: _describe(error),
      ));
    }

    // Notes are fetched alongside the check, not on demand from the About
    // panel: they describe the newest release either way, so there is nothing
    // to wait for a user action for, and a failure here must not turn a
    // successful check into a failed one.
    unawaited(_loadReleaseNotes());
  }

  Future<void> _checkAndroid() async {
    final check = await _androidUpdater.check();
    _androidCheck = check;

    if (check == null || !check.hasUpdate) {
      _emit(_status.copyWith(phase: AppUpdatePhase.upToDate));
      return;
    }
    _emit(_status.copyWith(
      phase: AppUpdatePhase.available,
      availableVersion: check.releaseVersion.toString(),
    ));
  }

  Future<void> _checkDesktop() async {
    final controller = await _desktopController();

    // A recovery pass that found a half-finished install owns the status: the
    // native installer may still be running, and checking for a *newer* release
    // on top of that would report "up to date" over the top of it. The package's
    // own startup path guards the same way; calling checkForUpdates() directly
    // means doing it here.
    if (controller.state is UpdateInstalling ||
        controller.state is UpdateReadyToInstall) {
      _readDesktopState(controller);
      return;
    }

    // checkVersion() throws on failure; checkForUpdates() returns a typed
    // result instead, which is what a user-triggered check wants.
    await controller.checkForUpdates();
    _readDesktopState(controller);
  }

  /// Translates `desktop_updater`'s state into [AppUpdateStatus].
  ///
  /// [UpdateFreshInstallRequired] gets its own phase rather than being folded
  /// into [AppUpdatePhase.available]: the controller *throws* from
  /// `downloadUpdate()` in that state, so an "available" mapping would offer a
  /// Download button that reliably fails. [UpdateBlockedBySupportPolicy] is
  /// different — the controller accepts a download there, treating it as
  /// mandatory — so it does map onto [AppUpdatePhase.available], with the
  /// deadline as the explanatory message.
  void _readDesktopState(DesktopUpdaterController controller) {
    final state = controller.state;
    switch (state) {
      case UpdateIdle():
      case UpdateChecking():
        _emit(_status.copyWith(phase: AppUpdatePhase.checking));
      case UpdateAvailable(:final descriptor):
        _emit(_status.copyWith(
          phase: AppUpdatePhase.available,
          availableVersion: descriptor.version,
          clearError: true,
        ));
      case UpdateFreshInstallRequired(:final descriptor):
        _emit(_status.copyWith(
          phase: AppUpdatePhase.freshInstallRequired,
          availableVersion: descriptor.version,
          clearError: true,
        ));
      case UpdateBlockedBySupportPolicy(:final descriptor):
        _emit(_status.copyWith(
          phase: AppUpdatePhase.available,
          availableVersion: descriptor.version,
          error: 'This version is no longer supported. Please update.',
        ));
      case UpdateDownloading(:final receivedBytes, :final totalBytes):
        _emit(_status.copyWith(
          phase: AppUpdatePhase.downloading,
          receivedBytes: receivedBytes,
          totalBytes: totalBytes,
        ));
      case UpdateReadyToInstall():
        _emit(_status.copyWith(phase: AppUpdatePhase.readyToInstall));
      case UpdateInstalling():
        _emit(_status.copyWith(phase: AppUpdatePhase.installing));
      case UpdateFailed(:final error):
        _emit(_status.copyWith(
          phase: AppUpdatePhase.failed,
          error: _describe(error),
        ));
    }
  }

  /// Downloads the waiting update.
  ///
  /// On desktop this stages it and leaves the status at
  /// [AppUpdatePhase.readyToInstall] — installing is a second, explicit step,
  /// because it restarts the app. On Android the system installer takes over as
  /// soon as the APK lands, so there is no such pause and the status runs
  /// straight through to [AppUpdatePhase.installing].
  Future<void> downloadUpdate() async {
    if (!_isSupported || _status.phase != AppUpdatePhase.available) return;

    _emit(_status.copyWith(
      phase: AppUpdatePhase.downloading,
      receivedBytes: 0,
      totalBytes: 0,
      clearError: true,
    ));

    try {
      if (Platform.isAndroid) {
        final check = _androidCheck;
        if (check == null) {
          throw StateError('No Android release has been checked for.');
        }
        await _androidUpdater.downloadAndInstall(
          check,
          onProgress: (received, total) => _emit(_status.copyWith(
            phase: AppUpdatePhase.downloading,
            receivedBytes: received,
            totalBytes: total,
          )),
        );
        _emit(_status.copyWith(phase: AppUpdatePhase.installing));
      } else {
        final controller = await _desktopController();
        // The controller notifies through _readDesktopState as progress
        // arrives, so the download's own states need no handling here.
        await controller.downloadUpdate();
      }
    } catch (error) {
      _emit(_status.copyWith(
        phase: AppUpdatePhase.failed,
        error: _describe(error),
      ));
    }
  }

  /// Opens the release's own download page in a browser.
  ///
  /// The only thing [AppUpdatePhase.freshInstallRequired] supports: the release
  /// is marked as needing a full reinstall, so there is nothing for the in-app
  /// updater to stage and `downloadUpdate()` would throw.
  Future<void> openFreshInstallDownload() async {
    if (!_isSupported ||
        Platform.isAndroid ||
        _status.phase != AppUpdatePhase.freshInstallRequired) {
      return;
    }
    try {
      final controller = await _desktopController();
      await controller.openFreshInstallDownload();
    } catch (error) {
      _emit(_status.copyWith(
        phase: AppUpdatePhase.failed,
        error: _describe(error),
      ));
    }
  }

  /// Desktop only: hands the staged update to the native installer, which
  /// replaces the app and relaunches it. Does not return in the normal case.
  Future<void> installUpdate() async {
    if (!_isSupported ||
        Platform.isAndroid ||
        _status.phase != AppUpdatePhase.readyToInstall) {
      return;
    }
    _emit(_status.copyWith(phase: AppUpdatePhase.installing, clearError: true));
    try {
      final controller = await _desktopController();
      await controller.restartApp();
    } catch (error) {
      _emit(_status.copyWith(
        phase: AppUpdatePhase.failed,
        error: _describe(error),
      ));
    }
  }

  Future<void> _loadReleaseNotes() async {
    if (_notesRequested && _status.notes != null) return;
    _notesRequested = true;
    try {
      final notes = await _releaseNotesFetcher.fetch();
      if (notes != null) _emit(_status.copyWith(notes: notes));
    } catch (_) {
      // Notes are decoration. A missing or malformed document leaves the panel
      // without a "What's new" block and changes nothing else.
    }
  }

  /// Builds the `desktop_updater` controller on first use.
  ///
  /// `skipInitialVersionCheck` is on because construction would otherwise start
  /// a check that reports only through `notifyListeners` — this service drives
  /// checks itself so every one of them has a caller to report to. The recovery
  /// pass that constructor would also have run is done explicitly here instead.
  Future<DesktopUpdaterController> _desktopController() async {
    final existing = _desktop;
    if (existing != null) return existing;

    final supportDir = await getApplicationSupportDirectory();
    final recoveryFile = File(
      '${supportDir.path}${Platform.pathSeparator}'
      'desktop_updater_pending_install.json',
    );

    final controller = DesktopUpdaterController(
      appArchiveUrl: kAppArchiveUrl,
      expectedPackageId: kUpdatePackageId,
      trustedReleasePublicKeys: kTrustedReleasePublicKeys,
      recoveryStore: NightMailUpdateRecoveryStore(recoveryFile),
      skipInitialVersionCheck: true,
    )..addListener(_onDesktopControllerChanged);

    _desktop = controller;
    await controller.recoverPendingInstall();
    return controller;
  }

  void _onDesktopControllerChanged() {
    final controller = _desktop;
    if (controller != null) _readDesktopState(controller);
  }

  void _emit(AppUpdateStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  static String _describe(Object error) {
    if (error is AndroidInstallException) return error.message;
    if (error is StateError) return error.message;
    return error.toString();
  }

  Future<void> dispose() async {
    _recheckTimer?.cancel();
    _recheckTimer = null;
    _desktop?.removeListener(_onDesktopControllerChanged);
    _desktop?.dispose();
    _desktop = null;
    await _controller.close();
  }
}
