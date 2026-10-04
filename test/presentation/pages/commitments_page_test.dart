import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
import 'package:nightmail/domain/usecases/commitments/run_commitments_agent.dart';
import 'package:nightmail/domain/usecases/get_cached_calendar_events.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/commitments/commitments_cubit.dart';
import 'package:nightmail/presentation/pages/commitments_page.dart';

import 'commitments_page_test.mocks.dart';

/// The Commitments pane over a real cubit with its collaborators mocked:
/// the four sections, the chips and counts they carry, the Done action, and
/// the setup card shown when Triage has no System One provider.
@GenerateMocks([
  AccountManager,
  EmailRepository,
  CommitmentRepository,
  DetectCommitments,
  GetCachedCalendarEvents,
  TaskReminderScheduleLocalDatasource,
  CreateCalendarEvent,
  UpdateCalendarEvent,
  RunCommitmentsAgent,
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
  late MockRunCommitmentsAgent runAgent;

  const account = MicrosoftAccount(
    id: 'acc',
    displayName: 'Work',
    emailAddress: 'me@example.com',
    tenantId: 'common',
  );

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  Commitment commitment({
    required CommitmentKind kind,
    required String emailId,
    required String who,
    required String subject,
    required DateTime emailDate,
    CommitmentDue due = CommitmentDue.none,
    int urgency = 0,
    int? estimatedMinutes,
  }) {
    return Commitment(
      id: Commitment.idFor(kind, emailId),
      accountId: 'acc',
      emailId: emailId,
      conversationId: 'conv-$emailId',
      kind: kind,
      status: CommitmentStatus.open,
      counterpart: EmailAddress(address: '$who@example.com', name: who),
      subject: subject,
      snippet: subject,
      due: due,
      urgency: urgency,
      confidence: 0.9,
      emailDate: emailDate,
      detectedAt: now,
      estimatedMinutes: estimatedMinutes,
    );
  }

  final ledgerRows = [
    // Promised just now, due today → "Today" chip, not overdue.
    commitment(
      kind: CommitmentKind.iOwe,
      emailId: 's1',
      who: 'Sarah',
      subject: 'Migration numbers',
      emailDate: now,
      due: CommitmentDue.today,
      urgency: 2,
    ),
    // Asked three days ago, no stated deadline → age, plus the model's
    // effort estimate.
    commitment(
      kind: CommitmentKind.theyOweMe,
      emailId: 's2',
      who: 'AWS Support',
      subject: 'Case 4471',
      emailDate: now.subtract(const Duration(days: 3)),
      estimatedMinutes: 120,
    ),
    // Received yesterday, needed a same-day reply → overdue.
    commitment(
      kind: CommitmentKind.needsAction,
      emailId: 'i1',
      who: 'James',
      subject: 'Database access',
      emailDate: now.subtract(const Duration(days: 1)),
      due: CommitmentDue.today,
      urgency: 1,
    ),
  ];

  Email inboxEmail(String id) => Email(
        id: id,
        subject: id,
        from: const EmailAddress(address: 'x@y.com'),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: now,
        importance: EmailImportance.normal,
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
    // The pane builds its natural-language assistant from get_it.
    runAgent = MockRunCommitmentsAgent();
    sl.registerSingleton<RunCommitmentsAgent>(runAgent);

    when(accounts.activeAccount).thenReturn(account);
    when(ledger.getCommitments(accountId: 'acc'))
        .thenAnswer((_) async => Right(ledgerRows));
    // Three of the four Inbox messages have been scanned; one produced a
    // needs-action row → "1 email needs action · 2 don't".
    when(ledger.getScannedEmailIds(accountId: 'acc'))
        .thenAnswer((_) async => const Right({'i1', 'i2', 'i3'}));
    when(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));
    when(emails.getCachedFolders('acc')).thenAnswer(
      (_) async => const Right([
        EmailFolder(id: 'INBOX', displayName: 'Inbox', totalItemCount: 4, unreadItemCount: 0),
        EmailFolder(id: 'SENT', displayName: 'Sent', totalItemCount: 2, unreadItemCount: 0),
      ]),
    );
    when(emails.getCachedEmails(accountId: 'acc', folderId: 'INBOX'))
        .thenAnswer((_) async => Right([
              for (final id in ['i1', 'i2', 'i3', 'i4']) inboxEmail(id),
            ]));
    when(emails.getCachedEmails(accountId: 'acc', folderId: 'SENT'))
        .thenAnswer((_) async => const Right([]));
    when(calendar(any)).thenAnswer(
      (_) async => Right([
        CalendarEvent(
          id: 'e1',
          subject: 'Project meeting',
          start: today.add(const Duration(hours: 9)),
          end: today.add(const Duration(hours: 10)),
          isAllDay: false,
        ),
      ]),
    );
    when(taskReminders.getScheduledTaskReminders('acc')).thenAnswer(
      (_) async => [
        ScheduledTaskReminderRecord(
          accountId: 'acc',
          listId: 'l',
          taskId: 't1',
          triggerAtMs: now.millisecondsSinceEpoch,
          dueAtMs: today.add(const Duration(hours: 17)).millisecondsSinceEpoch,
          osScheduled: false,
        ),
      ],
    );
    when(detect(any)).thenAnswer(
      (_) async => Right(DetectCommitmentsResult(
        commitments: ledgerRows,
        classified: 5,
        remaining: 0,
        resolved: 0,
      )),
    );
  });

  tearDown(() => sl.reset());

  CommitmentsCubit buildCubit() => CommitmentsCubit(
        accountManager: accounts,
        emailRepository: emails,
        commitmentRepository: ledger,
        detectCommitments: detect,
        getCachedCalendarEvents: calendar,
        taskReminders: taskReminders,
        createCalendarEvent: createEvent,
        updateCalendarEvent: updateEvent,
      );

  /// Pumps the pane at [width] (a side pane by default) — or, with [width]
  /// null, filling the test surface, which the board tests size like a screen.
  Future<void> pumpPane(
    WidgetTester tester, {
    double? width = 420,
    ValueChanged<Commitment>? onOpenEmail,
  }) async {
    if (width != null) {
      // A tall pane, so every section is built: the list is lazy, and a
      // section below the fold would not be findable.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    final pane = CommitmentsDayPanel(onClose: () {}, onOpenEmail: onOpenEmail);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<CommitmentsCubit>(
            create: (_) => buildCubit(),
            child: width == null ? pane : SizedBox(width: width, child: pane),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A screen-sized surface for the board layout.
  void useScreenSizedSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1680, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('shows the four sections with their rows, chips and counts',
      (tester) async {
    await pumpPane(tester);

    expect(find.text('Commitments'), findsOneWidget);
    for (final title in ['TODAY', 'YOU OWE', 'WAITING ON', 'NEEDS A DECISION']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    // Today: the meeting, the task count, and the two commitments due or
    // overdue today (Sarah's promise, James's request).
    expect(find.text('Project meeting'), findsOneWidget);
    expect(find.text('1 task due today'), findsOneWidget);

    // Sarah appears under Today and under You owe; James under Today and
    // Needs a decision; AWS only under Waiting on.
    expect(find.text('Sarah'), findsNWidgets(2));
    expect(find.text('James'), findsNWidgets(2));
    expect(find.text('AWS Support'), findsOneWidget);

    // Chips: a same-day promise is "Today"; a day-old same-day request is
    // "Overdue"; an undated wait shows its age and the model's estimate.
    expect(find.text('Today'), findsNWidgets(2));
    expect(find.text('Overdue'), findsNWidgets(2));
    expect(find.text('3 days · ~2 h'), findsOneWidget);

    // The decision count comes from the scan markers over the Inbox.
    expect(find.text("1 email needs action · 2 don't"), findsOneWidget);
    // And the scan line reports what the model just did.
    expect(find.textContaining('Checked 5 new emails'), findsOneWidget);
    expect(find.text('Set up commitment detection'), findsNothing);
  });

  testWidgets('Done closes a commitment through the ledger and drops its row',
      (tester) async {
    await pumpPane(tester);
    expect(find.text('Sarah'), findsNWidgets(2));

    // The first Done button belongs to the first row in Today: Sarah's
    // promise (most urgent first).
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pumpAndSettle();

    verify(ledger.setStatus(
      accountId: 'acc',
      id: 'iOwe:s1',
      status: CommitmentStatus.done,
      now: anyNamed('now'),
    )).called(1);
    expect(find.text('Sarah'), findsNothing);
    expect(find.text('No open promises.'), findsOneWidget);
  });

  testWidgets('without a Triage route the pane shows the setup card',
      (tester) async {
    when(ledger.getCommitments(accountId: 'acc'))
        .thenAnswer((_) async => const Right([]));
    when(detect(any)).thenAnswer(
      (_) async => const Left(NoProviderConfigured(message: 'Route Triage')),
    );

    await pumpPane(tester);

    expect(find.text('Set up commitment detection'), findsOneWidget);
    expect(find.text('Route Triage'), findsOneWidget);
    expect(find.text('Open AI settings'), findsOneWidget);
    // Still a usable pane: the empty sections explain themselves.
    expect(find.text('No open promises.'), findsOneWidget);
    expect(find.text('Nobody owes you anything.'), findsOneWidget);
  });

  testWidgets('a refresh re-runs the scan', (tester) async {
    await pumpPane(tester);
    clearInteractions(detect);

    await tester.tap(find.byTooltip('Check new mail for commitments'));
    await tester.pumpAndSettle();

    verify(detect(any)).called(1);
  });

  group('screen-sized window (board layout)', () {
    testWidgets('lays the four sections out side by side as columns of cards',
        (tester) async {
      useScreenSizedSurface(tester);
      await pumpPane(tester, width: null);

      // Same four sections, now column headers with counts.
      for (final title in ['TODAY', 'YOU OWE', 'WAITING ON', 'NEEDS A DECISION']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // Cards carry an explicit Open action the narrow rows do not: Sarah
      // and James appear twice (Today + their own column), AWS once → 5.
      expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(5));
      // The meeting tile shows its time range, not just a start time.
      expect(find.textContaining(' – '), findsOneWidget);
      expect(find.text('Project meeting'), findsOneWidget);
      expect(find.text('1 task due today'), findsOneWidget);
      // The decision count sits in that column's footer.
      expect(find.text("1 email needs action · 2 don't"), findsOneWidget);
      // Nothing is cut off horizontally at a screen-sized width.
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrower than the board threshold it stays a single column',
        (tester) async {
      useScreenSizedSurface(tester);
      await pumpPane(tester, width: CommitmentsDayPanel.kBoardMinWidth - 1);

      // The narrow rows have Done/Dismiss but no Open icon.
      expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(5));
    });

    testWidgets('Done on a card closes the commitment', (tester) async {
      useScreenSizedSurface(tester);
      await pumpPane(tester, width: null);

      // The Today column lists Sarah's promise first (most urgent).
      await tester.tap(find.byIcon(Icons.check_rounded).first);
      await tester.pumpAndSettle();

      verify(ledger.setStatus(
        accountId: 'acc',
        id: 'iOwe:s1',
        status: CommitmentStatus.done,
        now: anyNamed('now'),
      )).called(1);
      expect(find.text('Sarah'), findsNothing);
    });
  });

  testWidgets('onOpenEmail overrides how a row opens its message',
      (tester) async {
    Commitment? opened;
    await pumpPane(tester, onOpenEmail: (c) => opened = c);

    // Tap the Waiting-on row (AWS appears once).
    await tester.tap(find.text('AWS Support'));
    await tester.pumpAndSettle();

    expect(opened?.id, 'theyOweMe:s2');
    // No reading-pane fallback hint, since the override handled it.
    expect(find.textContaining('main window'), findsNothing);
  });

  test('ageLabel reads naturally at every scale', () {
    expect(ageLabel(const Duration(minutes: 20)), '<1 h');
    expect(ageLabel(const Duration(hours: 5)), '5 h');
    expect(ageLabel(const Duration(days: 1)), '1 day');
    expect(ageLabel(const Duration(days: 6)), '6 days');
    expect(ageLabel(const Duration(days: 20)), '2 wk');
    expect(ageLabel(const Duration(days: 90)), '3 mo');

    expect(effortLabel(const Duration(minutes: 15)), '~15 min');
    expect(effortLabel(const Duration(minutes: 60)), '~1 h');
    expect(effortLabel(const Duration(minutes: 90)), '~1.5 h');
    expect(effortLabel(const Duration(minutes: 240)), '~4 h');
  });

  testWidgets('Schedule on a row proposes a block and books it', (tester) async {
    when(ledger.setSchedule(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      eventId: anyNamed('eventId'),
      start: anyNamed('start'),
      end: anyNamed('end'),
    )).thenAnswer((_) async => Right(unit));
    when(createEvent(any)).thenAnswer((inv) async {
      final p = inv.positionalArguments.first as CreateCalendarEventParams;
      return Right(CalendarEvent(
        id: 'ev-1',
        subject: p.subject,
        start: p.start,
        end: p.end,
        isAllDay: false,
      ));
    });
    await pumpPane(tester);

    // The first Schedule button is on the first Today row: Sarah's promise.
    await tester.tap(find.byIcon(Icons.event_available_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('Schedule time'), findsOneWidget);
    expect(find.textContaining('Migration numbers'), findsWidgets);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Schedule'));
    await tester.pumpAndSettle();

    final params =
        verify(createEvent(captureAny)).captured.single as CreateCalendarEventParams;
    expect(params.subject, 'Migration numbers — for Sarah');
    expect(params.end.difference(params.start), const Duration(hours: 1));
    verify(ledger.setSchedule(
      accountId: 'acc',
      id: 'iOwe:s1',
      eventId: 'ev-1',
      start: params.start,
      end: params.end,
    )).called(1);
    // The dialog closed and the row now carries its block.
    expect(find.text('Schedule time'), findsNothing);
    expect(find.text('Time blocked for Sarah.'), findsOneWidget);
    expect(find.byIcon(Icons.event_rounded), findsWidgets);
  });

  testWidgets('the week-ahead strip is part of the pane', (tester) async {
    await pumpPane(tester);

    expect(find.text('WEEK AHEAD'), findsOneWidget);
    // One pressure cell per forecast day.
    final days = find.byTooltip(RegExp(r'.*'));
    expect(days, findsWidgets);
  });
}
