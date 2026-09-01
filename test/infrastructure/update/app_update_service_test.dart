import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/app_update_service.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';
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
}
