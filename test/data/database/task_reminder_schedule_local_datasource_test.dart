// ScheduledTaskReminders schema test (v11), following the round-trip pattern
// in reminder_schedule_local_datasource_test.dart: opens AppDatabase on an
// in-memory NativeDatabase (runs onCreate -> createAll(), the same createTable
// call the `if (from < 11)` upgrade branch performs) and round-trips rows
// through the TaskReminderScheduleLocalDatasource interface AppDatabase
// implements.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('ScheduledTaskReminders (v11)', () {
    test('upsert then get round-trips every column', () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: true,
      );

      final rows = await db.getScheduledTaskReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.listId, 'list1');
      expect(rows.single.taskId, 'task1');
      expect(rows.single.triggerAtMs, 1000);
      expect(rows.single.dueAtMs, 2000);
      expect(rows.single.osScheduled, isTrue);
      expect(rows.single.notifiedAtMs, isNull);
    });

    test('rows are scoped to their account', () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1', // same taskId, different account
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: false,
      );
      await db.upsertScheduledTaskReminder(
        accountId: 'acct2',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 5000,
        dueAtMs: 6000,
        osScheduled: false,
      );

      expect((await db.getScheduledTaskReminders('acct1')).single.triggerAtMs,
          1000);
      expect((await db.getScheduledTaskReminders('acct2')).single.triggerAtMs,
          5000);
    });

    test('(accountId, taskId) primary key means upsert replaces', () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: true,
        notifiedAtMs: 1500,
      );
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 9000,
        dueAtMs: 9500,
        osScheduled: false,
      );

      final rows = await db.getScheduledTaskReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.triggerAtMs, 9000);
      expect(rows.single.osScheduled, isFalse);
      // A rescheduled task is un-notified again — the new due moment has not
      // been announced yet.
      expect(rows.single.notifiedAtMs, isNull);
    });

    test('markTaskReminderNotified stamps only the matching row', () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: true,
      );
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task2',
        triggerAtMs: 3000,
        dueAtMs: 4000,
        osScheduled: true,
      );

      await db.markTaskReminderNotified(
        accountId: 'acct1',
        taskId: 'task1',
        notifiedAtMs: 7777,
      );

      final rows = await db.getScheduledTaskReminders('acct1');
      final byId = {for (final r in rows) r.taskId: r};
      expect(byId['task1']!.notifiedAtMs, 7777);
      expect(byId['task2']!.notifiedAtMs, isNull);
    });

    test('delete removes only the matching row', () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: false,
      );
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task2',
        triggerAtMs: 3000,
        dueAtMs: 4000,
        osScheduled: false,
      );

      await db.deleteScheduledTaskReminder('acct1', 'task1');

      final rows = await db.getScheduledTaskReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.taskId, 'task2');
    });

    test('clearScheduledTaskRemindersForAccount spares other accounts',
        () async {
      await db.upsertScheduledTaskReminder(
        accountId: 'acct1',
        listId: 'list1',
        taskId: 'task1',
        triggerAtMs: 1000,
        dueAtMs: 2000,
        osScheduled: false,
      );
      await db.upsertScheduledTaskReminder(
        accountId: 'acct2',
        listId: 'list1',
        taskId: 'task2',
        triggerAtMs: 3000,
        dueAtMs: 4000,
        osScheduled: false,
      );

      await db.clearScheduledTaskRemindersForAccount('acct1');

      expect(await db.getScheduledTaskReminders('acct1'), isEmpty);
      expect(await db.getScheduledTaskReminders('acct2'), hasLength(1));
    });
  });
}
