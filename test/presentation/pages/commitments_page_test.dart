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
import 'package:nightmail/domain/usecases/get_cached_calendar_events.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
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
])
void main() {
  late MockAccountManager accounts;
  late MockEmailRepository emails;
  late MockCommitmentRepository ledger;
  late MockDetectCommitments detect;
  late MockGetCachedCalendarEvents calendar;
  late MockTaskReminderScheduleLocalDatasource taskReminders;

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
    // Asked three days ago, no stated deadline → age only.
    commitment(
      kind: CommitmentKind.theyOweMe,
      emailId: 's2',
      who: 'AWS Support',
      subject: 'Case 4471',
      emailDate: now.subtract(const Duration(days: 3)),
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

  CommitmentsCubit buildCubit() => CommitmentsCubit(
        accountManager: accounts,
        emailRepository: emails,
        commitmentRepository: ledger,
        detectCommitments: detect,
        getCachedCalendarEvents: calendar,
        taskReminders: taskReminders,
      );

  Future<void> pumpPane(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<CommitmentsCubit>(
            create: (_) => buildCubit(),
            child: SizedBox(
              width: 420,
              child: CommitmentsDayPanel(onClose: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
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
    // "Overdue"; an undated wait shows only its age.
    expect(find.text('Today'), findsNWidgets(2));
    expect(find.text('Overdue'), findsNWidgets(2));
    expect(find.text('3 days'), findsOneWidget);

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

  test('ageLabel reads naturally at every scale', () {
    expect(ageLabel(const Duration(minutes: 20)), '<1 h');
    expect(ageLabel(const Duration(hours: 5)), '5 h');
    expect(ageLabel(const Duration(days: 1)), '1 day');
    expect(ageLabel(const Duration(days: 6)), '6 days');
    expect(ageLabel(const Duration(days: 20)), '2 wk');
    expect(ageLabel(const Duration(days: 90)), '3 mo');
  });
}
