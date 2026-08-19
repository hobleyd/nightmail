import 'package:equatable/equatable.dart';

/// Where an in-app update has got to.
///
/// One enum for two mechanisms. macOS/Windows go through `desktop_updater`
/// (check → download+verify+stage → hand to the native installer); Android
/// downloads an APK from the GitHub release and hands it to the system package
/// installer, which has no "staged" step of its own. [readyToInstall] is
/// therefore desktop-only, and [installing] is the last thing either platform
/// reports — after it, the process is being replaced.
enum AppUpdatePhase {
  /// No updater on this platform. Linux ships as a snap, which updates itself;
  /// iOS goes through the App Store; the web build has no installable form.
  unsupported,

  /// Nothing has been asked yet.
  idle,

  /// A check is in flight.
  checking,

  /// The check completed and this build is the newest one published.
  upToDate,

  /// A newer release exists and has not been downloaded.
  available,

  /// A newer release exists but the in-app updater cannot install it — the
  /// release is marked fresh-install-only, or is past a support deadline that
  /// requires a full reinstall. The only action is to open the download page;
  /// `desktop_updater` refuses [downloadUpdate] outright in this state, so this
  /// must not be folded into [available] or the button would always fail.
  freshInstallRequired,

  /// The new release is coming down.
  downloading,

  /// Desktop only: downloaded, verified and staged. Installing restarts the app.
  readyToInstall,

  /// Handed to the native installer.
  installing,

  /// The last check, download or install failed. See [AppUpdateStatus.error].
  failed,
}

/// One item of a hosted release-notes document.
class UpdateNoteItem extends Equatable {
  const UpdateNoteItem({required this.body, this.title});

  final String body;
  final String? title;

  @override
  List<Object?> get props => [body, title];
}

/// A titled group of [UpdateNoteItem]s — "New features", "Fixes", and so on.
class UpdateNoteSection extends Equatable {
  const UpdateNoteSection({required this.title, required this.items});

  final String title;
  final List<UpdateNoteItem> items;

  @override
  List<Object?> get props => [title, items];
}

/// The parsed contents of the hosted `release-notes.json`.
///
/// [version] is the release the notes describe, which is not necessarily the
/// running one: the document always describes the newest published release, so
/// on a machine that is up to date it is "what you already have" and on one
/// with an update waiting it is "what you are about to get".
class UpdateReleaseNotes extends Equatable {
  const UpdateReleaseNotes({
    required this.sections,
    this.version,
    this.summary,
  });

  final String? version;
  final String? summary;
  final List<UpdateNoteSection> sections;

  bool get isEmpty => sections.isEmpty && (summary == null || summary!.isEmpty);

  @override
  List<Object?> get props => [version, summary, sections];
}

/// What the About panel draws and what the Settings icon's dot is keyed off.
class AppUpdateStatus extends Equatable {
  const AppUpdateStatus({
    this.phase = AppUpdatePhase.idle,
    this.installedVersion,
    this.availableVersion,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.notes,
  });

  const AppUpdateStatus.unsupported()
      : phase = AppUpdatePhase.unsupported,
        installedVersion = null,
        availableVersion = null,
        receivedBytes = 0,
        totalBytes = 0,
        error = null,
        notes = null;

  final AppUpdatePhase phase;

  /// `version+buildNumber` of the running build, once it has been read.
  final String? installedVersion;

  /// Version of the release waiting, when one is.
  final String? availableVersion;

  final int receivedBytes;
  final int totalBytes;

  /// Human-readable reason the last operation failed.
  final String? error;

  final UpdateReleaseNotes? notes;

  /// Fraction downloaded, or null when the total is not yet known — which is
  /// what a [CircularProgressIndicator] wants for its indeterminate spin.
  double? get progress {
    if (totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  /// Whether there is something for the user to act on — the Settings icon's
  /// dot. A download already in flight is deliberately excluded: the user has
  /// acted, and a dot that stays lit while a progress bar runs reads as a
  /// second, separate thing still needing attention.
  bool get hasActionableUpdate =>
      phase == AppUpdatePhase.available ||
      phase == AppUpdatePhase.freshInstallRequired ||
      phase == AppUpdatePhase.readyToInstall;

  bool get isBusy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.installing;

  AppUpdateStatus copyWith({
    AppUpdatePhase? phase,
    String? installedVersion,
    String? availableVersion,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    UpdateReleaseNotes? notes,
    bool clearError = false,
    bool clearAvailableVersion = false,
  }) {
    return AppUpdateStatus(
      phase: phase ?? this.phase,
      installedVersion: installedVersion ?? this.installedVersion,
      availableVersion: clearAvailableVersion
          ? null
          : (availableVersion ?? this.availableVersion),
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      error: clearError ? null : (error ?? this.error),
      notes: notes ?? this.notes,
    );
  }

  @override
  List<Object?> get props => [
        phase,
        installedVersion,
        availableVersion,
        receivedBytes,
        totalBytes,
        error,
        notes,
      ];
}
