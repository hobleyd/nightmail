// Reconciliation behaviour of CalendarReminderService: which events get a
// reminder handed to the OS, and — the part worth the most cover — that an
// event whose start moves has its *previous* alert cancelled rather than left
// pending alongside the new one. Scheduling over the top is not a replacement:
// on Windows `zonedSchedule` appends a scheduled toast, so a missing cancel
// meant a postponed meeting still announced itself at its original time.
//
// The calendar datasource is mocked (mockito, per the repo convention) but the
// persistence is the real AppDatabase on an in-memory NativeDatabase, since the
// decision to reschedule is made by diffing against those rows.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/calendar_reminder_service.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';

import 'calendar_reminder_service_test.mocks.dart';

@GenerateMocks([AccountManager, NotificationService, CalendarRemoteDatasource])
void main() {
  const account = MicrosoftAccount(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'test@example.com',
    tenantId: 'common',
  );

  late AppDatabase db;
  late MockAccountManager accountManager;
  late MockNotificationService notifications;
  late MockCalendarRemoteDatasource calendarDatasource;
  late CalendarReminderService service;

  CalendarEventModel event(
    String id, {
    required DateTime start,
    int? reminderMinutes = 15,
  }) =>
      CalendarEventModel(
        id: id,
        subject: 'Event $id',
        start: start.toUtc(),
        end: start.toUtc().add(const Duration(minutes: 30)),
        isAllDay: false,
        reminderMinutes: reminderMinutes,
      );

  void stubEvents(List<CalendarEventModel> events) {
    when(calendarDatasource.getCalendarEvents(
      startDateTime: anyNamed('startDateTime'),
      endDateTime: anyNamed('endDateTime'),
    )).thenAnswer((_) async => events);
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    accountManager = MockAccountManager();
    notifications = MockNotificationService();
    calendarDatasource = MockCalendarRemoteDatasource();

    when(accountManager.accounts).thenReturn([account]);
    when(accountManager.activeAccount).thenReturn(account);
    when(accountManager.calendarDatasource).thenReturn(calendarDatasource);

    when(notifications.scheduleEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      eventTitle: anyNamed('eventTitle'),
      startUtc: anyNamed('startUtc'),
      reminderMinutes: anyNamed('reminderMinutes'),
      startIso: anyNamed('startIso'),
    )).thenAnswer((_) async {});
    when(notifications.cancelEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    )).thenAnswer((_) async {});

    service = CalendarReminderService(
      accountManager: accountManager,
      notificationService: notifications,
      database: db,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('schedules a reminder for an upcoming event with one set', () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);

    await service.reconcileAll();

    verify(notifications.scheduleEventReminder(
      accountId: account.id,
      eventId: 'e1',
      eventTitle: 'Event e1',
      startUtc: start,
      reminderMinutes: 15,
      startIso: anyNamed('startIso'),
    )).called(1);
    verifyNever(notifications.cancelEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    ));
  });

  test('leaves an unchanged event alone on the next pass', () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);

    await service.reconcileAll();
    clearInteractions(notifications);
    await service.reconcileAll();

    verifyNever(notifications.scheduleEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      eventTitle: anyNamed('eventTitle'),
      startUtc: anyNamed('startUtc'),
      reminderMinutes: anyNamed('reminderMinutes'),
      startIso: anyNamed('startIso'),
    ));
    verifyNever(notifications.cancelEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    ));
  });

  test('cancels the old alert before scheduling a postponed event', () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    // Postponed until tomorrow.
    final moved = start.add(const Duration(days: 1));
    stubEvents([event('e1', start: moved)]);
    await service.reconcileAll();

    verifyInOrder([
      notifications.cancelEventReminder(
          accountId: account.id, eventId: 'e1'),
      notifications.scheduleEventReminder(
        accountId: account.id,
        eventId: 'e1',
        eventTitle: 'Event e1',
        startUtc: moved,
        reminderMinutes: 15,
        startIso: anyNamed('startIso'),
      ),
    ]);
  });

  test('cancels the old alert when a moved start leaves no time to warn',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    // Brought forward to start in 5 minutes, so a 15-minute warning is already
    // in the past. scheduleEventReminder declines it — the stale alert for the
    // original time still has to go.
    final moved = DateTime.now().toUtc().add(const Duration(minutes: 5));
    stubEvents([event('e1', start: moved)]);
    await service.reconcileAll();

    verify(notifications.cancelEventReminder(
            accountId: account.id, eventId: 'e1'))
        .called(1);
  });

  test('cancels a reminder removed from an event that is still there',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    stubEvents([event('e1', start: start, reminderMinutes: null)]);
    await service.reconcileAll();

    verify(notifications.cancelEventReminder(
            accountId: account.id, eventId: 'e1'))
        .called(1);
    expect(await db.getScheduledReminders(account.id), isEmpty);
  });

  test('cancels a reminder for an event that dropped out of the window',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    stubEvents([]);
    await service.reconcileAll();

    verify(notifications.cancelEventReminder(
            accountId: account.id, eventId: 'e1'))
        .called(1);
    expect(await db.getScheduledReminders(account.id), isEmpty);
  });
}
