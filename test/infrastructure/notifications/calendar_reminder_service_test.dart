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

    when(notifications.osRetainsSchedule).thenReturn(true);
    // Default: the platform cannot be asked what it is holding, so the
    // persisted row is the only evidence there is. The tests that care about
    // the OS disagreeing with it stub this themselves.
    when(notifications.pendingReminders()).thenAnswer((_) async => null);
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
      schedulesReminders: true,
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('schedules a reminder for an upcoming event with one set', () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);

    await service.reconcileAll();

    // The cancel comes first even for an event with no row here: nothing this
    // side can prove the OS holds no alert for it (a build that scheduled one
    // alert per event, or a cleared cache, both leave some pending), and a
    // cancel for an id the OS never had costs nothing.
    verifyInOrder([
      notifications.cancelEventReminder(accountId: account.id, eventId: 'e1'),
      notifications.scheduleEventReminder(
        accountId: account.id,
        eventId: 'e1',
        eventTitle: 'Event e1',
        startUtc: start,
        reminderMinutes: 15,
        startIso: anyNamed('startIso'),
      ),
    ]);
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

  test('cancels the old alerts when a moved start leaves no time to warn',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    // Brought forward to start in 5 minutes, so the 15-minute warning is
    // already in the past — scheduleEventReminder skips that offset and keeps
    // only the tail of the countdown. The alerts queued for the original time
    // still have to go.
    final moved = DateTime.now().toUtc().add(const Duration(minutes: 5));
    stubEvents([event('e1', start: moved)]);
    await service.reconcileAll();

    verifyInOrder([
      notifications.cancelEventReminder(accountId: account.id, eventId: 'e1'),
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

  test('re-arms an unchanged event where the schedule dies with the process',
      () async {
    // Linux holds reminders in in-process timers, so a row matching an
    // unchanged event is no reason to believe anything is still queued for it.
    when(notifications.osRetainsSchedule).thenReturn(false);
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);

    await service.reconcileAll();
    clearInteractions(notifications);
    await service.reconcileAll();

    verify(notifications.scheduleEventReminder(
      accountId: account.id,
      eventId: 'e1',
      eventTitle: 'Event e1',
      startUtc: start,
      reminderMinutes: 15,
      startIso: anyNamed('startIso'),
    )).called(1);
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

  // --- The scheduling horizon, the alert budget, and checking the OS ---------
  //
  // A row in scheduled_reminders is a claim that the OS holds this series, and
  // the `unchanged` skip believes it. Everything below exists because that
  // claim used to be made for alerts the OS silently discarded: a fortnight of
  // a working calendar asks for several hundred pending alerts against a cap
  // of tens, and a dropped one was never re-armed for the life of the event.

  test('does not queue an event beyond the scheduling horizon', () async {
    // Inside the 14-day fetch, well outside the window alerts are queued for.
    final start = DateTime.now().toUtc().add(const Duration(days: 5));
    stubEvents([event('far', start: start)]);

    await service.reconcileAll();

    verifyNever(notifications.scheduleEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      eventTitle: anyNamed('eventTitle'),
      startUtc: anyNamed('startUtc'),
      reminderMinutes: anyNamed('reminderMinutes'),
      startIso: anyNamed('startIso'),
    ));
    // And no row, or the skip would silence it once it does come into range.
    expect(await db.getScheduledReminders(account.id), isEmpty);
  });

  test('queues an event once it comes inside the horizon', () async {
    final far = DateTime.now().toUtc().add(const Duration(days: 5));
    stubEvents([event('e1', start: far)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    // Brought forward — the same event, now a couple of hours away.
    final near = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: near)]);
    await service.reconcileAll();

    verify(notifications.scheduleEventReminder(
      accountId: account.id,
      eventId: 'e1',
      eventTitle: anyNamed('eventTitle'),
      startUtc: near,
      reminderMinutes: 15,
      startIso: anyNamed('startIso'),
    )).called(1);
  });

  test('gives up the furthest-away events when the alert budget runs out',
      () async {
    // 15 minutes of lead time expands to four alerts (15/10/5/0), so 20 events
    // ask for 80 against a budget of 48 — twelve events fit, the rest wait for
    // a later pass. Chronological, so what is dropped is what is furthest off.
    final base = DateTime.now().toUtc().add(const Duration(hours: 1));
    stubEvents([
      for (var i = 0; i < 20; i++)
        event('e$i', start: base.add(Duration(minutes: i * 30))),
    ]);

    await service.reconcileAll();

    final rows = await db.getScheduledReminders(account.id);
    expect(rows.length, 12);
    expect(
      rows.map((r) => r.eventId).toSet(),
      {for (var i = 0; i < 12; i++) 'e$i'},
    );
  });

  test('re-arms an unchanged event the OS is no longer holding alerts for',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    // The OS kept the lead-time alert and lost the rest of the countdown —
    // which is what happens when a request lands past the pending cap. The row
    // is unchanged, so without asking the OS this event is skipped for good.
    when(notifications.pendingReminders()).thenAnswer(
      (_) async => const PendingReminders.fromKeys({'acct-1::e1'}),
    );
    await service.reconcileAll();

    verifyInOrder([
      notifications.cancelEventReminder(accountId: account.id, eventId: 'e1'),
      notifications.scheduleEventReminder(
        accountId: account.id,
        eventId: 'e1',
        eventTitle: 'Event e1',
        startUtc: start,
        reminderMinutes: 15,
        startIso: anyNamed('startIso'),
      ),
    ]);
  });

  test('leaves an unchanged event alone when the OS still holds every alert',
      () async {
    final start = DateTime.now().toUtc().add(const Duration(hours: 2));
    stubEvents([event('e1', start: start)]);
    await service.reconcileAll();
    clearInteractions(notifications);

    when(notifications.pendingReminders()).thenAnswer(
      (_) async => const PendingReminders.fromKeys({
        'acct-1::e1',
        'acct-1::e1::10',
        'acct-1::e1::5',
        'acct-1::e1::0',
      }),
    );
    await service.reconcileAll();

    verifyNever(notifications.scheduleEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      eventTitle: anyNamed('eventTitle'),
      startUtc: anyNamed('startUtc'),
      reminderMinutes: anyNamed('reminderMinutes'),
      startIso: anyNamed('startIso'),
    ));
  });

  // --- Two accounts ---------------------------------------------------------
  //
  // The alert budget is per *app*, which is the whole reason the pass fetches
  // every account before it schedules anything. Spent one mailbox at a time it
  // would hand the first account everything, however much nearer the second
  // account's meetings were — and David's own install is Google beside Graph,
  // so this is the shape it ships into.

  group('an account this app does not have', () {
    // Both shapes the orphan takes. A debug build sharing this database adds
    // the same mailbox under a fresh id (the Keychain is per code signature)
    // and its reconciler writes rows and queues alerts nothing in the release
    // build's account list will ever revisit — which is how a meeting moved to
    // tomorrow still announced itself at today's time. A build with its own
    // data directory leaves only the alerts, so the OS's pending list is
    // checked as well.
    const gone = 'acct-gone';

    test('has its rows cleared and their alerts cancelled', () async {
      final start = DateTime.now().toUtc().add(const Duration(hours: 2));
      await db.upsertScheduledReminder(
        accountId: gone,
        eventId: 'e9',
        triggerAtMs:
            start.subtract(const Duration(minutes: 15)).millisecondsSinceEpoch,
        reminderMinutes: 15,
        eventStartMs: start.millisecondsSinceEpoch,
      );
      stubEvents([event('e1', start: start)]);

      await service.reconcileAll();

      verify(notifications.cancelEventReminder(accountId: gone, eventId: 'e9'))
          .called(1);
      expect(await db.getScheduledReminders(gone), isEmpty);
      // The configured account is reconciled as usual.
      expect(
        (await db.getScheduledReminders(account.id)).map((r) => r.eventId),
        ['e1'],
      );
    });

    test('has the alerts the OS holds for it cancelled, once per series',
        () async {
      final start = DateTime.now().toUtc().add(const Duration(hours: 2));
      when(notifications.pendingReminders()).thenAnswer(
        (_) async => PendingReminders.fromKeys({
          '$gone::e9',
          '$gone::e9::10',
          '$gone::e9::5',
          '$gone::e9::0',
          '${account.id}::e1',
        }),
      );
      stubEvents([event('e1', start: start)]);

      await service.reconcileAll();

      // cancelEventReminder clears a whole series, so the four keys collapse
      // into one call.
      final cancelled = verify(notifications.cancelEventReminder(
              accountId: gone, eventId: captureAnyNamed('eventId')))
          .captured;
      expect(cancelled, ['e9']);
    });

    test('is left alone while no account is configured at all', () async {
      // An empty account list is more likely the moment before they load than
      // a user who removed every one — clearAccount covers removal.
      await db.upsertScheduledReminder(
        accountId: gone,
        eventId: 'e9',
        triggerAtMs: 1000,
        reminderMinutes: 15,
        eventStartMs: 2000,
      );
      when(accountManager.accounts).thenReturn([]);

      await service.reconcileAll();

      expect(await db.getScheduledReminders(gone), hasLength(1));
      verifyNever(notifications.cancelEventReminder(
          accountId: gone, eventId: anyNamed('eventId')));
    });
  });

  group('PendingReminders.orphanedEvents', () {
    test('reads the account and event out of each key shape', () {
      const graphId =
          'AAMkAGMwOGJjZDQxLTRiMTctNDFiMS1hMzJhLTkzMWRmMDA3Yjc0ZAFRAAgI3xg8cgYAAEYAAAAAgn8OQYauCUOzHRg8eF5nJAcA7OVcF7-rJ0eKP7R3mFy9qQAAAAABDQAA7OVcF7-rJ0eKP7R3mFy9qQACtSGmqgAAEA==';
      const googleInstance = 'uep8t1rs2afu5djsl4rjrfpkkk_20260922T040000Z';
      final pending = PendingReminders.fromKeys({
        'known::$googleInstance',
        'known::$googleInstance::5',
        'gone-1::$googleInstance',
        'gone-1::$googleInstance::10',
        'gone-1::$googleInstance::0',
        'gone-2::$graphId::15',
        'malformed',
      });

      expect(pending.orphanedEvents({'known'}), {
        (accountId: 'gone-1', eventId: googleInstance),
        (accountId: 'gone-2', eventId: graphId),
      });
      expect(pending.orphanedEvents({'known', 'gone-1', 'gone-2'}), isEmpty);
    });
  });

  group('a build that must not hold reminders', () {
    // macOS files pending notification requests under the code-signing
    // identity that queued them, so a debug build's alerts are invisible to,
    // and uncancellable from, the release build sharing its bundle id. The
    // only build that can clear a debug run's leftovers is a debug run — so a
    // non-release build's pass drains its own queue and schedules nothing.
    setUp(() {
      when(notifications.drainReminders()).thenAnswer((_) async {});
      service = CalendarReminderService(
        accountManager: accountManager,
        notificationService: notifications,
        database: db,
        schedulesReminders: false,
      );
    });

    test('drains the OS queue and schedules nothing, without fetching',
        () async {
      final start = DateTime.now().toUtc().add(const Duration(hours: 2));
      stubEvents([event('e1', start: start)]);

      await service.reconcileAll();

      verify(notifications.drainReminders()).called(1);
      verifyNever(notifications.scheduleEventReminder(
        accountId: anyNamed('accountId'),
        eventId: anyNamed('eventId'),
        eventTitle: anyNamed('eventTitle'),
        startUtc: anyNamed('startUtc'),
        reminderMinutes: anyNamed('reminderMinutes'),
        startIso: anyNamed('startIso'),
      ));
      verifyNever(calendarDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      ));
      expect(await db.getScheduledReminders(account.id), isEmpty);
    });

    test("drops its own accounts' rows and leaves every other account's",
        () async {
      // The database is shared with the release build, whose rows are its
      // record of what it holds; deleting them would make it re-arm its whole
      // calendar on the next pass.
      for (final owner in [account.id, 'release-acct']) {
        await db.upsertScheduledReminder(
          accountId: owner,
          eventId: 'e1',
          triggerAtMs: 1000,
          reminderMinutes: 15,
          eventStartMs: 2000,
        );
      }

      await service.reconcileAll();

      expect(await db.getScheduledReminders(account.id), isEmpty);
      expect(await db.getScheduledReminders('release-acct'), hasLength(1));
      // The drain is what cancels — by what the OS holds, not by row — so no
      // per-event cancel is issued for anyone.
      verifyNever(notifications.cancelEventReminder(
          accountId: anyNamed('accountId'), eventId: anyNamed('eventId')));
    });
  });

  group('across two accounts', () {
    const second = GmailAccount(
      id: 'acct-2',
      displayName: 'Personal',
      emailAddress: 'me@example.com',
    );
    late MockCalendarRemoteDatasource secondDatasource;

    setUp(() {
      secondDatasource = MockCalendarRemoteDatasource();
      when(accountManager.accounts).thenReturn([account, second]);
      // The active account keeps AccountManager's shared datasource; anything
      // else is built per account.
      when(accountManager.buildCalendarDatasourceForAccount(second))
          .thenReturn(secondDatasource);
    });

    void stubSecondEvents(List<CalendarEventModel> events) {
      when(secondDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => events);
    }

    test('spends the budget by start time, not by account', () async {
      // Twelve events of four alerts each exhausts the 48-alert budget. The
      // first account offers twelve early ones and twelve late ones; the second
      // offers six that fall between them. Ordering by account would queue the
      // first account's twelve early events and nothing of the second's — the
      // point is that the second's six displace the first's later six.
      final base = DateTime.now().toUtc().add(const Duration(hours: 1));
      stubEvents([
        for (var i = 0; i < 12; i++)
          event('a$i', start: base.add(Duration(minutes: i * 10))),
      ]);
      stubSecondEvents([
        for (var i = 0; i < 6; i++)
          event('b$i', start: base.add(Duration(minutes: 5 + i * 10))),
      ]);

      await service.reconcileAll();

      final first =
          (await db.getScheduledReminders(account.id)).map((r) => r.eventId);
      final other =
          (await db.getScheduledReminders(second.id)).map((r) => r.eventId);
      expect(first.length + other.length, 12);
      // a0 b0 a1 b1 … a5 b5 by start time, then a6 onwards is over budget.
      expect(first.toSet(), {for (var i = 0; i < 6; i++) 'a$i'});
      expect(other.toSet(), {for (var i = 0; i < 6; i++) 'b$i'});
    });

    test('a failing fetch leaves that account\'s rows alone', () async {
      final start = DateTime.now().toUtc().add(const Duration(hours: 2));
      stubEvents([event('a1', start: start)]);
      stubSecondEvents([event('b1', start: start)]);
      await service.reconcileAll();
      expect(await db.getScheduledReminders(second.id), hasLength(1));
      clearInteractions(notifications);

      // The second account's calendar is unreachable this pass. A fetch that
      // did not happen is not evidence that a meeting was cancelled, so its row
      // must survive — deleting it would drop the claim that its alerts are
      // queued and, worse, cancel them.
      when(secondDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenThrow(Exception('auth expired'));
      await service.reconcileAll();

      expect(
        (await db.getScheduledReminders(second.id)).map((r) => r.eventId),
        ['b1'],
      );
      verifyNever(notifications.cancelEventReminder(
          accountId: second.id, eventId: anyNamed('eventId')));
      // And the account that did answer is still reconciled.
      expect(await db.getScheduledReminders(account.id), hasLength(1));
    });
  });
}
