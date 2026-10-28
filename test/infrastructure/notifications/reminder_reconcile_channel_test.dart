import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/notifications/reminder_reconcile_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A test engine is the main window, so this is the path a meeting cancelled
  // or dragged on the main window's own calendar takes — requestReconcile is a
  // no-op there, which is why reconcileNow exists.
  group('reconcileNow in the main window', () {
    test('runs the handler the main window registered', () async {
      var runs = 0;
      await ReminderReconcileChannel.listen(() async => runs++);

      await ReminderReconcileChannel.reconcileNow();

      expect(runs, 1);
    });

    test('swallows a handler that throws — the periodic cycle is the net',
        () async {
      await ReminderReconcileChannel.listen(
          () async => throw StateError('fetch failed'));

      await expectLater(ReminderReconcileChannel.reconcileNow(), completes);
    });
  });
}
