import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/repositories/commitment_repository.dart';
import 'package:nightmail/domain/usecases/commitments/agent/commitment_agent_tools.dart';
import 'package:nightmail/domain/usecases/commitments/forecast_workload.dart';
import 'package:nightmail/domain/usecases/commitments/schedule_commitment.dart';
import 'package:nightmail/domain/usecases/commitments/suggest_time_block.dart';

import 'commitment_agent_tools_test.mocks.dart';

@GenerateMocks([ScheduleCommitment, CommitmentRepository])
void main() {
  // Tuesday 6 October 2026, 09:00.
  final now = DateTime(2026, 10, 6, 9);
  final wed = DateTime(2026, 10, 7);
  final fri = DateTime(2026, 10, 9);

  DateTime at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  Commitment commitment({
    required String id,
    CommitmentKind kind = CommitmentKind.iOwe,
    CommitmentDue due = CommitmentDue.thisWeek,
    int urgency = 1,
    DateTime? scheduledStart,
    DateTime? scheduledEnd,
    CommitmentStatus status = CommitmentStatus.open,
  }) =>
      Commitment(
        id: Commitment.idFor(kind, id),
        accountId: 'acc',
        emailId: id,
        kind: kind,
        status: status,
        counterpart: const EmailAddress(address: 'sarah@client.com', name: 'Sarah'),
        subject: 'Subject $id',
        snippet: 'Excerpt $id',
        due: due,
        urgency: urgency,
        confidence: 0.9,
        emailDate: now.subtract(const Duration(days: 2)),
        detectedAt: now,
        scheduledEventId: scheduledStart == null ? null : 'ev-$id',
        scheduledStart: scheduledStart,
        scheduledEnd: scheduledEnd,
      );

  final open = commitment(id: 'a');
  final scheduled = commitment(
    id: 'b',
    scheduledStart: at(wed, 10),
    scheduledEnd: at(wed, 11),
    kind: CommitmentKind.needsAction,
  );
  final closed = commitment(id: 'c', status: CommitmentStatus.done);

  final events = [
    CalendarEvent(id: 'm1', subject: 'Standup', start: at(wed, 9), end: at(wed, 10), isAllDay: false),
    CalendarEvent(id: 'ev-b', subject: 'block', start: at(wed, 10), end: at(wed, 11), isAllDay: false),
  ];

  late MockScheduleCommitment scheduler;
  late MockCommitmentRepository ledger;
  late CommitmentToolContext ctx;

  setUp(() {
    provideDummy<Either<Failure, Commitment>>(Right(open));
    provideDummy<Either<Failure, Unit>>(Right(unit));
    scheduler = MockScheduleCommitment();
    ledger = MockCommitmentRepository();
    ctx = CommitmentToolContext(
      snapshot: CommitmentsAgentSnapshot(
        accountId: 'acc',
        commitments: [open, scheduled, closed],
        events: events,
        taskDueDates: [wed],
        now: now,
      ),
      scheduler: scheduler,
      ledger: ledger,
      suggester: const SuggestTimeBlock(),
      forecaster: const ForecastWorkload(),
    );
  });

  Map<String, dynamic> decode(Either<Failure, String> r) =>
      jsonDecode(r.getOrElse((f) => fail('$f'))) as Map<String, dynamic>;

  group('parsing', () {
    test('resolveDay reads today, tomorrow, weekday names and dates', () {
      expect(resolveDay('today', now), DateTime(2026, 10, 6));
      expect(resolveDay('Tomorrow', now), wed);
      expect(resolveDay('friday', now), fri);
      expect(resolveDay('Fri', now), fri);
      // Today's own weekday is today, not next week.
      expect(resolveDay('tuesday', now), DateTime(2026, 10, 6));
      expect(resolveDay('2026-10-12', now), DateTime(2026, 10, 12));
      expect(resolveDay('someday', now), isNull);
      expect(resolveDay(null, now), isNull);
    });

    test('parseLocalDateTime reads ISO local time and converts a Z', () {
      expect(parseLocalDateTime('2026-10-08T14:00'), DateTime(2026, 10, 8, 14));
      expect(parseLocalDateTime('2026-10-08T14:00:00Z')!.isUtc, isFalse);
      expect(parseLocalDateTime('2pm Thursday'), isNull);
    });
  });

  group('list_commitments', () {
    test('lists open commitments only, with ids, state and blocks', () async {
      final out = decode(await ListCommitmentsTool(ctx).invoke({}));
      expect(out['count'], 2);
      final items = (out['commitments'] as List).cast<Map<String, dynamic>>();
      expect(items.map((c) => c['id']), [open.id, scheduled.id]);
      final a = items.first;
      expect(a['kind'], 'i_owe');
      expect(a['who'], 'Sarah');
      expect(a['urgency'], 1);
      expect(a['overdue'], isFalse);
      expect(a['age_days'], 2);
      expect(a['scheduled'], isNull);
      final b = items.last;
      expect(b['kind'], 'needs_action');
      expect(b['scheduled'], {'start': '2026-10-07T10:00', 'end': '2026-10-07T11:00'});
    });

    test('filters by kind and by scheduled state', () async {
      final byKind = decode(await ListCommitmentsTool(ctx).invoke({'kind': 'needs_action'}));
      expect((byKind['commitments'] as List).single['id'], scheduled.id);
      final unscheduled = decode(await ListCommitmentsTool(ctx).invoke({'scheduled': false}));
      expect((unscheduled['commitments'] as List).single['id'], open.id);
    });
  });

  group('get_forecast', () {
    test('encodes the week with per-day load and the ids landing', () async {
      final out = decode(await GetForecastTool(ctx).invoke({}));
      expect(out['working_hours'], '9:00-17:00');
      final days = (out['days'] as List).cast<Map<String, dynamic>>();
      expect(days, hasLength(5));
      final wednesday = days.firstWhere((d) => d['date'] == '2026-10-07');
      expect(wednesday['weekday'], 'Wednesday');
      expect(wednesday['meeting_minutes'], 60); // the standup; the block is not a meeting
      expect(wednesday['blocked_minutes'], 60);
      expect(wednesday['tasks_due'], 1);
      expect(wednesday['landing_commitment_ids'], [scheduled.id]);
      expect(out.containsKey('open_slots_today'), isTrue);
    });
  });

  group('find_free_slot', () {
    test('finds the first run clear of meetings and blocks', () async {
      final out = decode(await FindFreeSlotTool(ctx).invoke({'day': 'wednesday', 'duration_minutes': 90}));
      expect(out['found'], isTrue);
      expect(out['start'], '2026-10-07T11:00');
      expect(out['end'], '2026-10-07T12:30');
    });

    test('reports an unreadable day', () async {
      final out = decode(await FindFreeSlotTool(ctx).invoke({'day': 'whenever'}));
      expect(out['error'], contains('Could not read the day'));
    });
  });

  group('schedule_block', () {
    test('books through the scheduler and reports overlaps', () async {
      when(scheduler.call(any, start: anyNamed('start'), end: anyNamed('end')))
          .thenAnswer((inv) async {
        final c = inv.positionalArguments.first as Commitment;
        return Right(c.copyWith(
          scheduledEventId: 'ev-new',
          scheduledStart: inv.namedArguments[#start] as DateTime,
          scheduledEnd: inv.namedArguments[#end] as DateTime,
        ));
      });

      // Into the standup: still booked, flagged.
      final out = decode(await ScheduleBlockTool(ctx).invoke({
        'commitment_id': open.id,
        'start': '2026-10-07T09:30',
        'duration_minutes': 30,
      }));
      expect(out['ok'], isTrue);
      expect(out['moved'], isFalse);
      expect(out['overlaps_meeting'], isTrue);
      expect(out['calendar_subject'], 'Subject a — for Sarah');
      verify(scheduler.call(open, start: at(wed, 9, 30), end: at(wed, 10))).called(1);
    });

    test('moving an existing block ignores its own event when checking overlap',
        () async {
      when(scheduler.call(any, start: anyNamed('start'), end: anyNamed('end')))
          .thenAnswer((inv) async => Right(scheduled));

      final out = decode(await ScheduleBlockTool(ctx).invoke({
        'commitment_id': scheduled.id,
        'start': '2026-10-07T10:30',
      }));
      expect(out['moved'], isTrue);
      // 10:30–11:30 overlaps only the block being moved → no conflict.
      expect(out['overlaps_meeting'], isFalse);
    });

    test('refuses a closed commitment and a bad start', () async {
      final closedOut = decode(await ScheduleBlockTool(ctx).invoke({
        'commitment_id': closed.id,
        'start': '2026-10-07T10:30',
      }));
      expect(closedOut['error'], contains('is done'));

      final badStart = decode(await ScheduleBlockTool(ctx).invoke({
        'commitment_id': open.id,
        'start': 'Thursday afternoon',
      }));
      expect(badStart['error'], contains('Could not read the start'));
      verifyNever(scheduler.call(any, start: anyNamed('start'), end: anyNamed('end')));
    });
  });

  group('mark_done / dismiss', () {
    test('set the status through the ledger', () async {
      when(ledger.setStatus(
        accountId: anyNamed('accountId'),
        id: anyNamed('id'),
        status: anyNamed('status'),
        now: anyNamed('now'),
      )).thenAnswer((_) async => Right(unit));

      final done = decode(await MarkDoneTool(ctx).invoke({'commitment_id': open.id}));
      expect(done, {'ok': true, 'commitment_id': open.id, 'status': 'done'});
      final dismissed = decode(await DismissTool(ctx).invoke({'commitment_id': scheduled.id}));
      expect(dismissed['status'], 'dismissed');
      verify(ledger.setStatus(accountId: 'acc', id: open.id, status: CommitmentStatus.done, now: now)).called(1);
      verify(ledger.setStatus(accountId: 'acc', id: scheduled.id, status: CommitmentStatus.dismissed, now: now)).called(1);
    });
  });
}
