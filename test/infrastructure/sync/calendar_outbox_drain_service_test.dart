// Replay behaviour of the calendar outbox: that each op reaches the right
// provider call, that a failure quarantines only its own meeting, and that an op
// which can never succeed is dropped rather than retried forever.
//
// The queue is the real AppDatabase on an in-memory NativeDatabase, since
// dequeue-on-success and retry-counting are its behaviour.

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/pending_calendar_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/domain/entities/meeting_notify_scope.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/sync/calendar_outbox_drain_service.dart';

import 'calendar_outbox_drain_service_test.mocks.dart';

@GenerateMocks([
  AccountManager,
  CalendarRemoteDatasource,
  ConnectivityService,
])
void main() {
  const account = GmailAccount(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'me@example.com',
  );

  late AppDatabase db;
  late MockAccountManager accountManager;
  late MockCalendarRemoteDatasource datasource;
  late MockConnectivityService connectivity;
  late CalendarOutboxDrainService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    accountManager = MockAccountManager();
    datasource = MockCalendarRemoteDatasource();
    connectivity = MockConnectivityService();

    when(accountManager.accounts).thenReturn([account]);
    when(accountManager.activeAccount).thenReturn(account);
    when(accountManager.calendarDatasource).thenReturn(datasource);
    when(connectivity.isOnline).thenAnswer((_) async => true);

    service = CalendarOutboxDrainService(
      pendingOperations: db,
      accountManager: accountManager,
      connectivityService: connectivity,
    );
  });

  tearDown(() => db.close());

  Future<int> enqueue(
    PendingCalendarOperationType type,
    String targetId, [
    Map<String, dynamic> payload = const {},
  ]) =>
      db.enqueueCalendarOperation(
        accountId: account.id,
        targetId: targetId,
        opType: type,
        payload: jsonEncode(payload),
      );

  group('replay', () {
    test('a queued decline is sent with the account address and dequeued',
        () async {
      when(datasource.declineCalendarEvent(
        eventId: anyNamed('eventId'),
        userEmail: anyNamed('userEmail'),
      )).thenAnswer((_) async {});
      await enqueue(PendingCalendarOperationType.declineEvent, 'event-1');

      await service.drainForAccount(account.id);

      verify(datasource.declineCalendarEvent(
              eventId: 'event-1', userEmail: 'me@example.com'))
          .called(1);
      expect(await db.getPendingCalendarOperations(account.id), isEmpty);
    });

    test('a queued cancel reaches the provider', () async {
      when(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')))
          .thenAnswer((_) async {});
      await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

      await service.drainForAccount(account.id);

      verify(datasource.cancelCalendarEvent(eventId: 'event-1')).called(1);
    });

    test('a queued series cancel carries its master id and occurrence start',
        () async {
      when(datasource.cancelCalendarEventSeries(
        eventId: anyNamed('eventId'),
        seriesMasterId: anyNamed('seriesMasterId'),
        occurrenceStart: anyNamed('occurrenceStart'),
      )).thenAnswer((_) async {});
      final start = DateTime.utc(2026, 6, 10, 9);
      await enqueue(PendingCalendarOperationType.cancelSeries, 'occ-1', {
        'seriesMasterId': 'master-1',
        'occurrenceStart': start.toIso8601String(),
      });

      await service.drainForAccount(account.id);

      verify(datasource.cancelCalendarEventSeries(
        eventId: 'occ-1',
        seriesMasterId: 'master-1',
        occurrenceStart: start,
      )).called(1);
    });

    test('a queued RSVP is sent against the invitation email id', () async {
      when(datasource.respondToMeetingInvite(
        emailId: anyNamed('emailId'),
        response: anyNamed('response'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        userEmail: anyNamed('userEmail'),
        message: anyNamed('message'),
      )).thenAnswer((_) async {});
      final start = DateTime.utc(2026, 6, 10, 9);
      await enqueue(PendingCalendarOperationType.respondToInvite, 'mail-1', {
        'response': 'tentative',
        'icsData': 'BEGIN:VCALENDAR',
        'meetingStart': start.toIso8601String(),
        'message': 'Might be late',
      });

      await service.drainForAccount(account.id);

      verify(datasource.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.tentative,
        icsData: 'BEGIN:VCALENDAR',
        meetingStart: start,
        userEmail: 'me@example.com',
        message: 'Might be late',
      )).called(1);
    });

    test('a queued update round-trips its save params through the payload',
        () async {
      final start = DateTime.utc(2026, 6, 11, 14);
      final original = UpdateCalendarEventParams(
        id: 'event-1',
        subject: 'Moved',
        start: start,
        end: start.add(const Duration(hours: 1)),
        isAllDay: false,
        timezone: 'Australia/Sydney',
        location: 'Room 2',
        description: 'Agenda',
        attendeeEmails: const ['bob@corp.com'],
        recurrence: CalendarRecurrence(
          frequency: RecurrenceFrequency.weekly,
          interval: 2,
          daysOfWeek: const [1, 4],
        ),
        reminderMinutes: 10,
        notifyScope: MeetingNotifyScope.changedAttendeesOnly,
      );
      when(datasource.updateCalendarEvent(params: anyNamed('params')))
          .thenAnswer((_) async => CalendarEventModel(
                id: 'event-1',
                subject: 'Moved',
                start: start,
                end: start.add(const Duration(hours: 1)),
                isAllDay: false,
              ));

      await enqueue(
        PendingCalendarOperationType.updateEvent,
        'event-1',
        CalendarOutboxDrainService.updateParamsToJson(original),
      );
      await service.drainForAccount(account.id);

      final sent = verify(datasource.updateCalendarEvent(
              params: captureAnyNamed('params')))
          .captured
          .single as UpdateCalendarEventParams;
      // The params have been through JSON and back; nothing may be lost on the
      // way, or a queued edit would silently save something else.
      expect(sent, original);
    });
  });

  group('failure handling', () {
    test('offline, nothing is sent and the queue is untouched', () async {
      when(connectivity.isOnline).thenAnswer((_) async => false);
      await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

      await service.drainForAccount(account.id);

      verifyNever(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')));
      expect(await db.getPendingCalendarOperations(account.id), hasLength(1));
    });

    test('a transient failure leaves the op queued with the reason recorded',
        () async {
      when(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')))
          .thenThrow(const NetworkException(message: 'timed out'));
      await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

      await service.drainForAccount(account.id);

      final op = (await db.getPendingCalendarOperations(account.id)).single;
      expect(op.retryCount, 1);
      expect(op.lastError, contains('timed out'));
    });

    test('a 404 drops the op — the meeting is already gone', () async {
      when(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')))
          .thenThrow(const ServerException(message: 'gone', statusCode: 404));
      await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

      await service.drainForAccount(account.id);

      expect(await db.getPendingCalendarOperations(account.id), isEmpty);
    });

    test('one meeting failing does not hold up another', () async {
      when(datasource.cancelCalendarEvent(eventId: 'bad'))
          .thenThrow(const NetworkException(message: 'timed out'));
      when(datasource.cancelCalendarEvent(eventId: 'good'))
          .thenAnswer((_) async {});
      await enqueue(PendingCalendarOperationType.cancelEvent, 'bad');
      await enqueue(PendingCalendarOperationType.cancelEvent, 'good');

      await service.drainForAccount(account.id);

      verify(datasource.cancelCalendarEvent(eventId: 'good')).called(1);
      final remaining = await db.getPendingCalendarOperations(account.id);
      expect(remaining.map((o) => o.targetId), ['bad']);
    });

    test('a later op for the same meeting is skipped once one fails', () async {
      when(datasource.declineCalendarEvent(
        eventId: anyNamed('eventId'),
        userEmail: anyNamed('userEmail'),
      )).thenThrow(const NetworkException(message: 'timed out'));
      when(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')))
          .thenAnswer((_) async {});
      await enqueue(PendingCalendarOperationType.declineEvent, 'event-1');
      await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

      await service.drainForAccount(account.id);

      // Sending the cancel before the decline it was queued behind would apply
      // the user's actions out of order.
      verifyNever(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')));
      expect(await db.getPendingCalendarOperations(account.id), hasLength(2));
    });
  });

  test('concurrent drains do not replay the same op twice', () async {
    when(datasource.cancelCalendarEvent(eventId: anyNamed('eventId')))
        .thenAnswer((_) async {});
    await enqueue(PendingCalendarOperationType.cancelEvent, 'event-1');

    await Future.wait([
      service.drainForAccount(account.id),
      service.drainForAccount(account.id),
    ]);

    verify(datasource.cancelCalendarEvent(eventId: 'event-1')).called(1);
  });
}
