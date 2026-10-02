import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/local/task_reminder_schedule_local_datasource.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/repositories/commitment_repository.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/usecases/commitments/detect_commitments.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/get_cached_calendar_events.dart';
import 'package:nightmail/domain/usecases/get_calendar_events.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/presentation/blocs/commitments/commitments_cubit.dart';
import 'package:nightmail/presentation/blocs/commitments/commitments_state.dart';

import 'commitments_cubit_test.mocks.dart';

@GenerateMocks([
  AccountManager,
  EmailRepository,
  CommitmentRepository,
  DetectCommitments,
  GetCachedCalendarEvents,
  TaskReminderScheduleLocalDatasource,
  CreateCalendarEvent,
  UpdateCalendarEvent,
])
void main() {
  late MockAccountManager accounts;
  late MockEmailRepository emails;
  late MockCommitmentRepository ledger;
  late MockDetectCommitments detect;
  late MockGetCachedCalendarEvents calendar;
  late MockTaskReminderScheduleLocalDatasource taskReminders;
  late MockCreateCalendarEvent createEvent;
  late MockUpdateCalendarEvent updateEvent;
  late CommitmentsCubit cubit;

  final now = DateTime(2026, 10, 2, 9);
  const account = MicrosoftAccount(
    id: 'acc',
    displayName: 'Work',
    emailAddress: 'Me@Example.com',
    tenantId: 'common',
  );

  const folders = [
    EmailFolder(id: 'g1', displayName: 'Inbox', totalItemCount: 1, unreadItemCount: 0),
    EmailFolder(id: 'g2', displayName: 'Sent Items', totalItemCount: 1, unreadItemCount: 0),
    EmailFolder(id: 'g3', displayName: 'Archive', totalItemCount: 1, unreadItemCount: 0),
  ];

  Email email(String id, {required DateTime date}) => Email(
        id: id,
        subject: id,
        from: const EmailAddress(address: 'x@y.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: date,
        importance: EmailImportance.normal,
      );

  final inbox = [email('i1', date: now), email('i2', date: now)];
  final sent = [email('s1', date: now)];

  Commitment open(String emailId, CommitmentKind kind) => Commitment(
        id: Commitment.idFor(kind, emailId),
        accountId: 'acc',
        emailId: emailId,
        kind: kind,
        status: CommitmentStatus.open,
        counterpart: const EmailAddress(address: 'x@y.com'),
        subject: 's',
        snippet: '',
        due: CommitmentDue.none,
        urgency: 0,
        confidence: 0.9,
        emailDate: now,
        detectedAt: now,
      );

  setUp(() {
    provideDummy<Either<Failure, List<Commitment>>>(const Right([]));
    provideDummy<Either<Failure, Set<String>>>(const Right({}));
    provideDummy<Either<Failure, Unit>>(Right(unit));
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
    provideDummy<Either<Failure, List<Email>>>(const Right([]));
    provideDummy<Either<Failure, List<CalendarEvent>>>(const Right([]));
    provideDummy<Either<Failure, CalendarEvent>>(
      Right(CalendarEvent(
        id: 'dummy',
        subject: '',
        start: now,
        end: now,
        isAllDay: false,
      )),
    );
    provideDummy<Either<Failure, DetectCommitmentsResult>>(
      const Right(DetectCommitmentsResult(
        commitments: [],
        classified: 0,
        remaining: 0,
        resolved: 0,
      )),
    );

    accounts = MockAccountManager();
    emails = MockEmailRepository();
    ledger = MockCommitmentRepository();
    detect = MockDetectCommitments();
    calendar = MockGetCachedCalendarEvents();
    taskReminders = MockTaskReminderScheduleLocalDatasource();
    createEvent = MockCreateCalendarEvent();
    updateEvent = MockUpdateCalendarEvent();

    when(accounts.activeAccount).thenReturn(account);
    when(ledger.getCommitments(accountId: anyNamed('accountId')))
        .thenAnswer((_) async => const Right([]));
    when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
        .thenAnswer((_) async => const Right({'i1', 's1'}));
    when(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));
    when(emails.getCachedFolders('acc'))
        .thenAnswer((_) async => const Right(folders));
    when(emails.getCachedEmails(accountId: 'acc', folderId: 'g1'))
        .thenAnswer((_) async => Right(inbox));
    when(emails.getCachedEmails(accountId: 'acc', folderId: 'g2'))
        .thenAnswer((_) async => Right(sent));
    when(calendar(any)).thenAnswer((_) async => const Right([]));
    when(taskReminders.getScheduledTaskReminders('acc')).thenAnswer(
      (_) async => [
        ScheduledTaskReminderRecord(
          accountId: 'acc',
          listId: 'l',
          taskId: 't-today',
          triggerAtMs: now.millisecondsSinceEpoch,
          dueAtMs: DateTime(2026, 10, 2, 17).millisecondsSinceEpoch,
          osScheduled: false,
        ),
        ScheduledTaskReminderRecord(
          accountId: 'acc',
          listId: 'l',
          taskId: 't-tomorrow',
          triggerAtMs: now.millisecondsSinceEpoch,
          dueAtMs: DateTime(2026, 10, 3, 17).millisecondsSinceEpoch,
          osScheduled: false,
        ),
      ],
    );
    when(detect(any)).thenAnswer(
      (_) async => Right(DetectCommitmentsResult(
        commitments: [open('s1', CommitmentKind.iOwe)],
        classified: 2,
        remaining: 0,
        resolved: 0,
      )),
    );

    cubit = CommitmentsCubit(
      accountManager: accounts,
      emailRepository: emails,
      commitmentRepository: ledger,
      detectCommitments: detect,
      getCachedCalendarEvents: calendar,
      taskReminders: taskReminders,
      createCalendarEvent: createEvent,
      updateCalendarEvent: updateEvent,
      now: () => now,
    );
  });

  tearDown(() => cubit.close());

  test('without an active account it reports an error', () async {
    when(accounts.activeAccount).thenReturn(null);

    await cubit.load();

    expect(cubit.state.status, CommitmentsStatus.error);
    verifyNever(detect(any));
  });

  test('load paints the cached ledger, then scans the Sent and Inbox caches',
      () async {
    when(ledger.getCommitments(accountId: 'acc')).thenAnswer(
      (_) async => Right([open('i1', CommitmentKind.needsAction)]),
    );

    final states = <CommitmentsState>[];
    final sub = cubit.stream.listen(states.add);
    await cubit.load();
    await pumpEventQueue();
    await sub.cancel();

    expect(
      states.map((s) => s.status),
      containsAllInOrder([
        CommitmentsStatus.loading,
        CommitmentsStatus.loaded,
        CommitmentsStatus.scanning,
        CommitmentsStatus.loaded,
      ]),
    );
    // The first loaded state shows the ledger from disk...
    final firstLoaded =
        states.firstWhere((s) => s.status == CommitmentsStatus.loaded);
    expect(firstLoaded.commitments.map((c) => c.id), ['needsAction:i1']);
    expect(firstLoaded.tasksDueToday, 1);
    // ...and the final one what the scan produced.
    final last = cubit.state;
    expect(last.status, CommitmentsStatus.loaded);
    expect(last.commitments.map((c) => c.id), ['iOwe:s1']);
    expect(last.lastClassified, 2);
    expect(last.lastScanAt, now);
    expect(last.inboxScanned, 1); // i1 scanned, i2 not yet
    expect(last.needsTriageRoute, isFalse);

    final params =
        verify(detect(captureAny)).captured.single as DetectCommitmentsParams;
    expect(params.accountId, 'acc');
    expect(params.selfAddresses, {'me@example.com'});
    expect(params.sentEmails, sent);
    expect(params.inboxEmails, inbox);
    expect(params.now, now);
  });

  test('a missing Triage route is a setup prompt, not an error', () async {
    when(detect(any)).thenAnswer(
      (_) async => const Left(NoProviderConfigured(message: 'Route Triage')),
    );

    await cubit.load();
    await pumpEventQueue();

    expect(cubit.state.status, CommitmentsStatus.loaded);
    expect(cubit.state.needsTriageRoute, isTrue);
    expect(cubit.state.message, 'Route Triage');
  });

  test('a failed scan with nothing on screen is an error; with a ledger it is '
      'a message', () async {
    when(detect(any)).thenAnswer(
      (_) async => const Left(ProviderUnreachable(message: 'down')),
    );

    await cubit.load();
    await pumpEventQueue();
    expect(cubit.state.status, CommitmentsStatus.error);

    when(ledger.getCommitments(accountId: 'acc')).thenAnswer(
      (_) async => Right([open('i1', CommitmentKind.needsAction)]),
    );
    await cubit.load();
    await pumpEventQueue();
    expect(cubit.state.status, CommitmentsStatus.loaded);
    expect(cubit.state.message, 'down');
    expect(cubit.state.commitments, hasLength(1));
  });

  test('markDone persists and updates the row in place', () async {
    await cubit.load();
    await pumpEventQueue();
    expect(cubit.state.iOwe, hasLength(1));

    await cubit.markDone('iOwe:s1');

    verify(ledger.setStatus(
      accountId: 'acc',
      id: 'iOwe:s1',
      status: CommitmentStatus.done,
      now: now,
    )).called(1);
    expect(cubit.state.iOwe, isEmpty);
    expect(cubit.state.commitments.single.status, CommitmentStatus.done);
    expect(cubit.state.commitments.single.resolvedAt, now);
  });

  test('concurrent scans share one run', () async {
    await cubit.load();
    await pumpEventQueue();
    clearInteractions(detect);

    await Future.wait([cubit.scan(), cubit.scan()]);

    verify(detect(any)).called(1);
  });

  group('scheduling', () {
    CalendarEvent meeting(String id, DateTime start, DateTime end) =>
        CalendarEvent(id: id, subject: id, start: start, end: end, isAllDay: false);

    // `now` is Friday 2 Oct 2026 09:00: Friday is busy all day, Monday is
    // clear, so the lightest day in a "this week" horizon is Monday 5 Oct.
    final friday = DateTime(2026, 10, 2);
    final monday = DateTime(2026, 10, 5);

    test('suggestTimeBlock reads two weeks of cached calendar and picks the '
        'lightest day', () async {
      when(calendar(any)).thenAnswer((_) async => Right([
            meeting('fri', DateTime(2026, 10, 2, 9), DateTime(2026, 10, 2, 17)),
          ]));
      await cubit.load();
      await pumpEventQueue();

      final c = open('s1', CommitmentKind.iOwe);
      final s = await cubit.suggestTimeBlock(c);

      expect(s.start, DateTime(2026, 10, 5, 9));
      expect(s.hasConflict, isFalse);
      final params = verify(calendar(captureAny)).captured.last as GetCalendarEventsParams;
      expect(params.startDateTime, friday);
      expect(params.endDateTime, friday.add(CommitmentsCubit.scheduleLookahead));
      expect(params.accountId, 'acc');
      expect(s.days.first.day, friday);
      expect(s.days.map((d) => d.day), contains(monday));
    });

    test('schedule books a readable block and records it on the ledger',
        () async {
      await cubit.load();
      await pumpEventQueue();
      when(ledger.setSchedule(
        accountId: anyNamed('accountId'),
        id: anyNamed('id'),
        eventId: anyNamed('eventId'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      )).thenAnswer((_) async => Right(unit));
      final start = DateTime(2026, 10, 5, 9);
      final end = DateTime(2026, 10, 5, 10);
      when(createEvent(any)).thenAnswer(
        (_) async => Right(meeting('ev-1', start, end)),
      );

      final ok = await cubit.schedule(
        cubit.state.commitments.single,
        start: start,
        end: end,
      );

      expect(ok, isTrue);
      final params =
          verify(createEvent(captureAny)).captured.single as CreateCalendarEventParams;
      expect(params.subject, 's — for x@y.com');
      expect(params.start, start);
      expect(params.end, end);
      expect(params.isAllDay, isFalse);
      expect(params.reminderMinutes, CommitmentsCubit.blockReminderMinutes);
      expect(params.description, contains('Something you promised'));
      verify(ledger.setSchedule(
        accountId: 'acc',
        id: 'iOwe:s1',
        eventId: 'ev-1',
        start: start,
        end: end,
      )).called(1);
      final c = cubit.state.commitments.single;
      expect(c.isScheduled, isTrue);
      expect(c.scheduledEventId, 'ev-1');
      expect(c.scheduledStart, start);
      verifyNever(updateEvent(any));
    });

    test('rescheduling moves the existing event, creating anew only if the '
        'move fails', () async {
      final scheduled = open('s1', CommitmentKind.iOwe).copyWith(
        scheduledEventId: 'ev-old',
        scheduledStart: DateTime(2026, 10, 5, 9),
        scheduledEnd: DateTime(2026, 10, 5, 10),
      );
      when(detect(any)).thenAnswer((_) async => Right(DetectCommitmentsResult(
            commitments: [scheduled],
            classified: 0,
            remaining: 0,
            resolved: 0,
          )));
      when(ledger.setSchedule(
        accountId: anyNamed('accountId'),
        id: anyNamed('id'),
        eventId: anyNamed('eventId'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      )).thenAnswer((_) async => Right(unit));
      await cubit.load();
      await pumpEventQueue();
      final start = DateTime(2026, 10, 6, 14);
      final end = DateTime(2026, 10, 6, 15);

      // The move succeeds: no create.
      when(updateEvent(any)).thenAnswer(
        (_) async => Right(meeting('ev-old', start, end)),
      );
      expect(await cubit.schedule(scheduled, start: start, end: end), isTrue);
      final moved =
          verify(updateEvent(captureAny)).captured.single as UpdateCalendarEventParams;
      expect(moved.id, 'ev-old');
      expect(moved.start, start);
      verifyNever(createEvent(any));

      // The event was deleted by hand: the move fails, a new block is made.
      when(updateEvent(any)).thenAnswer(
        (_) async => const Left(ServerFailure(message: 'gone')),
      );
      when(createEvent(any)).thenAnswer(
        (_) async => Right(meeting('ev-new', start, end)),
      );
      expect(await cubit.schedule(scheduled, start: start, end: end), isTrue);
      verify(createEvent(any)).called(1);
      expect(cubit.state.commitments.single.scheduledEventId, 'ev-new');
    });

    test('a calendar refusal is reported and nothing is recorded', () async {
      await cubit.load();
      await pumpEventQueue();
      when(createEvent(any)).thenAnswer(
        (_) async => const Left(ServerFailure(message: 'calendar down')),
      );

      final ok = await cubit.schedule(
        cubit.state.commitments.single,
        start: DateTime(2026, 10, 5, 9),
        end: DateTime(2026, 10, 5, 10),
      );

      expect(ok, isFalse);
      expect(cubit.state.message, 'calendar down');
      expect(cubit.state.commitments.single.isScheduled, isFalse);
      verifyNever(ledger.setSchedule(
        accountId: anyNamed('accountId'),
        id: anyNamed('id'),
        eventId: anyNamed('eventId'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      ));
    });
  });
}
