import 'package:desktop_updater/desktop_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/app_update_service.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';
import 'package:nightmail/infrastructure/update/release_notes_fetcher.dart';
import 'package:nightmail/presentation/blocs/update/update_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an unsupported platform — a sub-window, or Linux', () {
    late AppUpdateService service;

    setUp(() {
      // The same answer _platformIsSupported() gives inside a
      // desktop_multi_window sub-window, and on Linux where snapd owns updates.
      service = AppUpdateService(isSupportedOverride: false);
    });

    tearDown(() => service.dispose());

    test('reports unsupported and never leaves it', () async {
      await service.start();
      expect(service.status.phase, AppUpdatePhase.unsupported);
    });

    test('every action is a no-op, so no second engine can install', () async {
      await service.start();

      await service.checkForUpdate();
      expect(service.status.phase, AppUpdatePhase.unsupported);

      await service.downloadUpdate();
      expect(service.status.phase, AppUpdatePhase.unsupported);

      await service.installUpdate();
      expect(service.status.phase, AppUpdatePhase.unsupported);
    });

    test('the dot stays dark', () async {
      await service.start();
      expect(service.status.hasActionableUpdate, isFalse);
    });
  });

  group('UpdateCubit', () {
    test('adopts the status the service already has, without waiting', () async {
      final service = AppUpdateService(isSupportedOverride: false);
      addTearDown(service.dispose);

      // The service is started before any cubit attaches — which is what
      // happens when Settings is opened long after launch.
      await service.start();

      final cubit = UpdateCubit(service: service);
      addTearDown(cubit.close);

      cubit.start();
      expect(cubit.state.phase, AppUpdatePhase.unsupported);
    });

    test('forwards later changes from the service', () async {
      final service = AppUpdateService(isSupportedOverride: false);
      addTearDown(service.dispose);

      final cubit = UpdateCubit(service: service)..start();
      addTearDown(cubit.close);

      final emitted = <AppUpdatePhase>[];
      final sub = cubit.stream.listen((s) => emitted.add(s.phase));
      addTearDown(sub.cancel);

      await service.start();
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(AppUpdatePhase.unsupported));
    });
  });

  group('how a waiting release is named', () {
    test('carries the build number, as the installed version does', () {
      // The About panel prints the installed version as `version+build`, so a
      // semver-only available version made the two lines compare different
      // things — "Version 1.22.2 is available" against "1.22.2+21".
      expect(formatReleaseVersion('1.22.3', 157), '1.22.3+157');
    });

    test('names a same-semver release by the only part that differs', () {
      // The whole of desktop_updater's comparison is the build number, so this
      // is a genuine update and the semver alone could not say why.
      expect(formatReleaseVersion('1.22.2', 156), '1.22.2+156');
    });

    test('falls back to the semver when there is no build number', () {
      // The Android path: the GitHub tag is stripped to its semver part, so
      // there is no build number to report.
      expect(formatReleaseVersion('1.22.3', null), '1.22.3');
    });
  });

  group('reading desktop_updater\'s state', () {
    const checking = AppUpdateStatus(phase: AppUpdatePhase.checking);

    test('idle says nothing, because it cannot say "up to date"', () {
      // The whole of the spinner-never-stops bug. The controller has no
      // up-to-date state: a check that found nothing newer lands back on
      // UpdateIdle, which is also what it holds before anything is checked.
      // Reporting a phase for it — checking, or up-to-date — is a claim the
      // state does not support, so it reports no change and _checkDesktop
      // reads the typed result of checkForUpdates() instead.
      expect(desktopStatusFor(const UpdateIdle(), checking), isNull);
    });

    test('a check in flight is the only thing that turns the spinner', () {
      expect(
        desktopStatusFor(const UpdateChecking(), const AppUpdateStatus())?.phase,
        AppUpdatePhase.checking,
      );
    });

    test('an available release is named with its build number', () {
      final next = desktopStatusFor(
        UpdateAvailable(descriptor: _descriptor(), mandatory: false),
        checking,
      );

      expect(next?.phase, AppUpdatePhase.available);
      expect(next?.availableVersion, '1.22.3+157');
    });

    test('a fresh-install release keeps its own phase', () {
      // Folding it into `available` would offer a Download button that throws.
      final next = desktopStatusFor(
        UpdateFreshInstallRequired(
          descriptor: _descriptor(),
          freshInstall: ReleaseFreshInstall(
            downloadUrl: Uri.parse('${kUpdateBaseUrl}download'),
          ),
          mandatory: true,
        ),
        checking,
      );

      expect(next?.phase, AppUpdatePhase.freshInstallRequired);
      expect(next?.availableVersion, '1.22.3+157');
    });

    test('download progress carries its counters', () {
      final next = desktopStatusFor(
        const UpdateDownloading(receivedBytes: 512, totalBytes: 1024),
        checking,
      );

      expect(next?.phase, AppUpdatePhase.downloading);
      expect(next?.progress, 0.5);
    });

    test('a failure reports its message', () {
      final next = desktopStatusFor(
        UpdateFailed(StateError('archive unreachable')),
        checking,
      );

      expect(next?.phase, AppUpdatePhase.failed);
      expect(next?.error, 'archive unreachable');
    });
  });

  group('the release notes beside the status', () {
    test('are re-read on every check, not once per process', () async {
      // The document always describes whatever release is newest when it is
      // fetched, so holding the first answer left a long-running app showing
      // "What's new in 1.22.3" beside "Version 1.22.4 is available".
      final fetcher = _CountingNotesFetcher();
      // A supported platform, so the check takes its desktop path — which fails
      // here for want of a platform channel. The notes load either way.
      final service = AppUpdateService(
        isSupportedOverride: true,
        releaseNotesFetcher: fetcher,
      );
      addTearDown(service.dispose);

      await service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);
      expect(fetcher.calls, 1);

      await service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);
      expect(fetcher.calls, 2, reason: 'a second check must re-read them');

      expect(service.status.notes.first.version, '1.22.4');
    });

    test('a failed re-read leaves the notes already on screen alone', () async {
      final fetcher = _CountingNotesFetcher();
      final service = AppUpdateService(
        isSupportedOverride: true,
        releaseNotesFetcher: fetcher,
      );
      addTearDown(service.dispose);

      await service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);

      fetcher.throwOnNextFetch = true;
      await service.checkForUpdate();
      await Future<void>.delayed(Duration.zero);

      expect(service.status.notes.first.version, '1.22.4');
    });
  });
}

/// Counts fetches, so a re-read can be told from a cached first answer.
class _CountingNotesFetcher extends ReleaseNotesFetcher {
  _CountingNotesFetcher() : super(url: kReleaseNotesUrl);

  int calls = 0;
  bool throwOnNextFetch = false;

  @override
  Future<List<UpdateReleaseNotes>> fetch() async {
    calls++;
    if (throwOnNextFetch) throw Exception('release-notes.json unreachable');
    return const [
      UpdateReleaseNotes(version: '1.22.4', sections: []),
      UpdateReleaseNotes(version: '1.22.3', sections: []),
    ];
  }
}

/// A minimal descriptor for the release the archive is offering.
ReleaseDescriptor _descriptor() => ReleaseDescriptor(
      schemaVersion: 3,
      packageId: kUpdatePackageId,
      appName: 'nightmail',
      version: '1.22.3',
      buildNumber: 157,
      platform: 'macos',
      channel: 'stable',
      artifact: ReleaseArtifact(
        kind: 'zip',
        url: Uri.parse('${kUpdateBaseUrl}releases/1.22.3+157-macos/app.zip'),
        sha256: '',
        length: 1024,
      ),
      install: const ReleaseInstall(strategy: 'wholeBundleReplace'),
      minimumUpdaterVersion: '3.0.0',
      generatedAt: DateTime.utc(2026, 9, 2),
    );
