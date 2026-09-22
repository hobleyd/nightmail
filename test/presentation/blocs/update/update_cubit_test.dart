import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/infrastructure/update/app_update_service.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';
import 'package:nightmail/presentation/blocs/update/update_cubit.dart';

import 'update_cubit_test.mocks.dart';

const _idle = AppUpdateStatus(phase: AppUpdatePhase.idle);
const _checking = AppUpdateStatus(phase: AppUpdatePhase.checking);
const _available = AppUpdateStatus(
  phase: AppUpdatePhase.available,
  availableVersion: '2.0.0',
);

@GenerateMocks([AppUpdateService])
void main() {
  late MockAppUpdateService mockService;
  late StreamController<AppUpdateStatus> changes;

  setUp(() {
    mockService = MockAppUpdateService();
    changes = StreamController<AppUpdateStatus>.broadcast();
    when(mockService.changes).thenAnswer((_) => changes.stream);
  });

  tearDown(() => changes.close());

  test('the initial state is whatever the service already holds', () {
    when(mockService.status).thenReturn(_checking);
    final cubit = UpdateCubit(service: mockService);
    addTearDown(cubit.close);

    expect(cubit.state, _checking);
  });

  group('start', () {
    test('forwards status changes published after it starts', () async {
      when(mockService.status).thenReturn(_idle);
      when(mockService.start()).thenAnswer((_) async {});
      final cubit = UpdateCubit(service: mockService);
      addTearDown(cubit.close);

      cubit.start();
      changes.add(_available);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state, _available);
      verify(mockService.start()).called(1);
    });

    test('adopts the service\'s current status if it already moved on before '
        'start() was called', () {
      // status() is read once at construction; a caller that constructs the
      // cubit and only calls start() later (HomePage does this every build)
      // must not stay stuck on the stale value if the service moved on in
      // between.
      when(mockService.status).thenReturn(_idle);
      final cubit = UpdateCubit(service: mockService);
      addTearDown(cubit.close);
      expect(cubit.state, _idle);

      when(mockService.status).thenReturn(_available);
      when(mockService.start()).thenAnswer((_) async {});
      cubit.start();

      expect(cubit.state, _available);
    });

    test('is safe to call repeatedly without re-subscribing', () async {
      when(mockService.status).thenReturn(_idle);
      when(mockService.start()).thenAnswer((_) async {});
      final cubit = UpdateCubit(service: mockService);
      addTearDown(cubit.close);

      cubit.start();
      cubit.start();
      cubit.start();

      verify(mockService.start()).called(3);
      // A single subscription would still only see one event per publish.
      var eventCount = 0;
      changes.stream.listen((_) => eventCount++);
      changes.add(_checking);
      await Future<void>.delayed(Duration.zero);
      expect(eventCount, 1);
    });
  });

  group('actions forward to the service', () {
    late UpdateCubit cubit;

    setUp(() {
      when(mockService.status).thenReturn(_idle);
      cubit = UpdateCubit(service: mockService);
    });

    tearDown(() => cubit.close());

    test('check', () async {
      when(mockService.checkForUpdate()).thenAnswer((_) async {});
      await cubit.check();
      verify(mockService.checkForUpdate()).called(1);
    });

    test('download', () async {
      when(mockService.downloadUpdate()).thenAnswer((_) async {});
      await cubit.download();
      verify(mockService.downloadUpdate()).called(1);
    });

    test('openFreshInstallDownload', () async {
      when(mockService.openFreshInstallDownload()).thenAnswer((_) async {});
      await cubit.openFreshInstallDownload();
      verify(mockService.openFreshInstallDownload()).called(1);
    });

    test('install', () async {
      when(mockService.installUpdate()).thenAnswer((_) async {});
      await cubit.install();
      verify(mockService.installUpdate()).called(1);
    });

    test('openHelperApprovalSettings', () async {
      when(mockService.openHelperApprovalSettings()).thenAnswer((_) async {});
      await cubit.openHelperApprovalSettings();
      verify(mockService.openHelperApprovalSettings()).called(1);
    });
  });

  group('checkOnOpen', () {
    UpdateCubit cubitAt(AppUpdatePhase phase) {
      when(mockService.status).thenReturn(AppUpdateStatus(phase: phase));
      when(mockService.checkForUpdate()).thenAnswer((_) async {});
      final cubit = UpdateCubit(service: mockService);
      addTearDown(cubit.close);
      return cubit;
    }

    for (final phase in [
      AppUpdatePhase.idle,
      AppUpdatePhase.upToDate,
      AppUpdatePhase.failed,
      // A newer release may have shipped since this one was found, and the
      // periodic timer skips its cycle while an update is actionable.
      AppUpdatePhase.available,
      AppUpdatePhase.freshInstallRequired,
    ]) {
      test('re-checks from $phase without blocking the caller', () {
        final cubit = cubitAt(phase);
        cubit.checkOnOpen();
        verify(mockService.checkForUpdate()).called(1);
      });
    }

    for (final phase in [
      AppUpdatePhase.checking,
      AppUpdatePhase.downloading,
      AppUpdatePhase.installing,
      // A staged update is left alone: on the snap path a fresh check drops the
      // downloaded file, and nothing a check finds changes what to press.
      AppUpdatePhase.readyToInstall,
      AppUpdatePhase.helperApprovalRequired,
    ]) {
      test('leaves $phase alone', () {
        final cubit = cubitAt(phase);
        cubit.checkOnOpen();
        verifyNever(mockService.checkForUpdate());
      });
    }

    test('an unsupported platform is still asked, and the service declines',
        () {
      // The service already answers "unsupported" with a no-op; the cubit does
      // not need to know which platforms those are.
      final cubit = cubitAt(AppUpdatePhase.unsupported);
      cubit.checkOnOpen();
      verify(mockService.checkForUpdate()).called(1);
    });
  });

  test('close cancels the subscription so a later publish is not emitted',
      () async {
    when(mockService.status).thenReturn(_idle);
    when(mockService.start()).thenAnswer((_) async {});
    final cubit = UpdateCubit(service: mockService);
    cubit.start();

    await cubit.close();
    // Adding after close must not throw a "Cannot emit after close" error.
    changes.add(_available);
    await Future<void>.delayed(Duration.zero);
  });
}
