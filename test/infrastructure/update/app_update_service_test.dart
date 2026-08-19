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
}
