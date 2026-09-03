import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';

void main() {
  group('hasActionableUpdate — what lights the Settings icon dot', () {
    test('lights when an update is found, and when one is staged', () {
      for (final phase in [
        AppUpdatePhase.available,
        // A fresh-install-only release is still an update the user should act
        // on; only the action differs.
        AppUpdatePhase.freshInstallRequired,
        AppUpdatePhase.readyToInstall,
      ]) {
        expect(
          AppUpdateStatus(phase: phase).hasActionableUpdate,
          isTrue,
          reason: '$phase should light the dot',
        );
      }
    });

    test('stays dark while a download the user started is running', () {
      // The user has already acted; a dot beside a progress bar reads as a
      // second thing still needing attention.
      expect(
        const AppUpdateStatus(phase: AppUpdatePhase.downloading)
            .hasActionableUpdate,
        isFalse,
      );
    });

    test('stays dark for every phase with nothing to act on', () {
      for (final phase in [
        AppUpdatePhase.unsupported,
        AppUpdatePhase.idle,
        AppUpdatePhase.checking,
        AppUpdatePhase.upToDate,
        AppUpdatePhase.installing,
        AppUpdatePhase.failed,
      ]) {
        expect(
          AppUpdateStatus(phase: phase).hasActionableUpdate,
          isFalse,
          reason: '$phase should not light the dot',
        );
      }
    });
  });

  group('leaving a download behind', () {
    test('a re-check clears the byte counters, so progress goes back to null',
        () {
      // A failed download used to leave receivedBytes/totalBytes in place, so
      // every later status reported a fraction for a transfer that had stopped.
      const failed = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        receivedBytes: 12345,
        totalBytes: 50000,
        error: 'network',
      );
      expect(failed.progress, isNotNull);

      final rechecking = failed.copyWith(
        phase: AppUpdatePhase.checking,
        receivedBytes: 0,
        totalBytes: 0,
        clearError: true,
      );
      expect(rechecking.progress, isNull);
      expect(rechecking.error, isNull);
    });
  });

  group('progress', () {
    test('is null until the total is known, so the bar spins', () {
      expect(const AppUpdateStatus(receivedBytes: 10).progress, isNull);
    });

    test('is the fraction received, clamped', () {
      expect(
        const AppUpdateStatus(receivedBytes: 50, totalBytes: 200).progress,
        0.25,
      );
      expect(
        const AppUpdateStatus(receivedBytes: 300, totalBytes: 200).progress,
        1.0,
      );
    });
  });

  group('copyWith', () {
    test('clearError removes an error a plain copy would carry forward', () {
      const failed = AppUpdateStatus(
        phase: AppUpdatePhase.failed,
        error: 'boom',
      );
      expect(failed.copyWith(phase: AppUpdatePhase.checking).error, 'boom');
      expect(
        failed.copyWith(phase: AppUpdatePhase.checking, clearError: true).error,
        isNull,
      );
    });

    test('clearAvailableVersion drops a version a re-check has invalidated',
        () {
      const available = AppUpdateStatus(
        phase: AppUpdatePhase.available,
        availableVersion: '1.21.0',
      );
      expect(
        available.copyWith(clearAvailableVersion: true).availableVersion,
        isNull,
      );
    });

    test('keeps the installed version across a phase change', () {
      const status = AppUpdateStatus(installedVersion: '1.20.0+17');
      expect(
        status.copyWith(phase: AppUpdatePhase.upToDate).installedVersion,
        '1.20.0+17',
      );
    });
  });

  test('equality is by value, so an unchanged status is not re-emitted', () {
    expect(
      const AppUpdateStatus(phase: AppUpdatePhase.upToDate),
      const AppUpdateStatus(phase: AppUpdatePhase.upToDate),
    );
    expect(
      const AppUpdateStatus(phase: AppUpdatePhase.upToDate),
      isNot(const AppUpdateStatus(phase: AppUpdatePhase.available)),
    );
  });

  test('the notes compare by value, not by list identity', () {
    // They are fetched afresh on every check, so a new-but-equal list arrives
    // every 6 hours. Comparing by identity would re-emit a status in which
    // nothing changed — the same trap MailPollerState documents.
    AppUpdateStatus withNotes() => AppUpdateStatus(
          phase: AppUpdatePhase.upToDate,
          notes: [
            const UpdateReleaseNotes(version: '1.22.4', sections: []),
            UpdateReleaseNotes(
              version: '1.22.3',
              sections: [
                const UpdateNoteSection(
                  title: 'Fixes',
                  items: [UpdateNoteItem(body: 'a fix')],
                ),
              ],
            ),
          ],
        );

    expect(withNotes(), withNotes());
    expect(
      withNotes(),
      isNot(const AppUpdateStatus(phase: AppUpdatePhase.upToDate)),
    );
  });
}
