// ScheduledReminders schema test (v9), following the round-trip pattern in
// ai_migration_test.dart: opens AppDatabase on an in-memory NativeDatabase
// (runs onCreate -> createAll(), the same createTable call the `if (from < 9)`
// upgrade branch performs) and round-trips rows through the new table via
// the ReminderScheduleLocalDatasource interface AppDatabase implements.

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

  group('ScheduledReminders (v9)', () {
    test('upsertScheduledReminder then getScheduledReminders round-trips',
        () async {
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );

      final rows = await db.getScheduledReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.eventId, 'evt1');
      expect(rows.single.triggerAtMs, 1000);
      expect(rows.single.reminderMinutes, 15);
      expect(rows.single.eventStartMs, 2000);
    });

    test('getScheduledReminders only returns rows for the given account',
        () async {
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );
      await db.upsertScheduledReminder(
        accountId: 'acct2',
        eventId: 'evt1', // same eventId, different account
        triggerAtMs: 5000,
        reminderMinutes: 30,
        eventStartMs: 6000,
      );

      final acct1Rows = await db.getScheduledReminders('acct1');
      expect(acct1Rows, hasLength(1));
      expect(acct1Rows.single.triggerAtMs, 1000);

      final acct2Rows = await db.getScheduledReminders('acct2');
      expect(acct2Rows, hasLength(1));
      expect(acct2Rows.single.triggerAtMs, 5000);
    });

    test('(accountId, eventId) primary key means upsert replaces', () async {
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 9000,
        reminderMinutes: 5,
        eventStartMs: 9500,
      );

      final rows = await db.getScheduledReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.triggerAtMs, 9000);
      expect(rows.single.reminderMinutes, 5);
    });

    test('deleteScheduledReminder removes only the matching row', () async {
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt2',
        triggerAtMs: 3000,
        reminderMinutes: 10,
        eventStartMs: 4000,
      );

      await db.deleteScheduledReminder('acct1', 'evt1');

      final rows = await db.getScheduledReminders('acct1');
      expect(rows, hasLength(1));
      expect(rows.single.eventId, 'evt2');
    });

    test('clearScheduledRemindersForAccount removes all rows for that account only',
        () async {
      await db.upsertScheduledReminder(
        accountId: 'acct1',
        eventId: 'evt1',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );
      await db.upsertScheduledReminder(
        accountId: 'acct2',
        eventId: 'evt2',
        triggerAtMs: 3000,
        reminderMinutes: 10,
        eventStartMs: 4000,
      );

      await db.clearScheduledRemindersForAccount('acct1');

      expect(await db.getScheduledReminders('acct1'), isEmpty);
      expect(await db.getScheduledReminders('acct2'), hasLength(1));
    });
  });
}
