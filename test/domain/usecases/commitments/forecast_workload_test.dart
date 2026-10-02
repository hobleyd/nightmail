import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/commitments/forecast_workload.dart';

void main() {
  const forecast = ForecastWorkload(); // 9–17, 5 working days, 60/30 min

  // Tuesday 6 October 2026, 09:00.
  final now = DateTime(2026, 10, 6, 9);
  final tue = DateTime(2026, 10, 6);
  final wed = DateTime(2026, 10, 7);
  final thu = DateTime(2026, 10, 8);
  final fri = DateTime(2026, 10, 9);
  final nextMon = DateTime(2026, 10, 12);

  DateTime at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  Commitment commitment({
    required String id,
    CommitmentDue due = CommitmentDue.none,
    int urgency = 1,
    DateTime? emailDate,
    DateTime? scheduledStart,
    DateTime? scheduledEnd,
    String? eventId,
    CommitmentStatus status = CommitmentStatus.open,
  }) =>
      Commitment(
        id: 'iOwe:$id',
        accountId: 'acc',
        emailId: id,
        kind: CommitmentKind.iOwe,
        status: status,
        counterpart: const EmailAddress(address: 'x@y.com', name: 'X'),
        subject: id,
        snippet: '',
        due: due,
        urgency: urgency,
        confidence: 0.9,
        emailDate: emailDate ?? now,
        detectedAt: now,
        scheduledEventId: eventId,
        scheduledStart: scheduledStart,
        scheduledEnd: scheduledEnd,
      );

  CalendarEvent meeting(String id, DateTime start, DateTime end) =>
      CalendarEvent(id: id, subject: id, start: start, end: end, isAllDay: false);

  group('horizon and landing', () {
    test('today plus the following working days, weekend skipped', () {
      expect(forecast.horizon(now), [tue, wed, thu, fri, nextMon]);
      expect(forecast.horizon(DateTime(2026, 10, 10, 11)).first, nextMon);
    });

    test('a commitment lands by its block, else by its due reading', () {
      final days = forecast.horizon(now);
      expect(
        forecast.landingDay(
          commitment(id: 'b', scheduledStart: at(thu, 10), scheduledEnd: at(thu, 11), eventId: 'e'),
          now,
          days,
        ),
        thu,
      );
      expect(forecast.landingDay(commitment(id: 't', due: CommitmentDue.today), now, days), tue);
      // Overdue (a "today" from yesterday) lands on today.
      expect(
        forecast.landingDay(
          commitment(id: 'o', due: CommitmentDue.today, emailDate: now.subtract(const Duration(days: 1))),
          now,
          days,
        ),
        tue,
      );
      // "This week" lands on the week's last working day in the horizon.
      expect(forecast.landingDay(commitment(id: 'w', due: CommitmentDue.thisWeek), now, days), fri);
      expect(forecast.landingDay(commitment(id: 'l', due: CommitmentDue.later), now, days), isNull);
      expect(forecast.landingDay(commitment(id: 'n'), now, days), isNull);
    });
  });

  group('day load', () {
    test('blocks are demand, not meetings; estimates cover the rest', () {
      final f = forecast(
        commitments: [
          commitment(id: 'blocked', scheduledStart: at(thu, 10), scheduledEnd: at(thu, 11, 30), eventId: 'block-1'),
          commitment(id: 'due-thu', due: CommitmentDue.thisWeek), // lands Fri, not Thu
          commitment(id: 'closed', status: CommitmentStatus.done, due: CommitmentDue.today),
        ],
        events: [
          meeting('m1', at(thu, 9), at(thu, 12)),
          // The user's own block appears in the calendar too; it must not be
          // counted as a meeting as well.
          meeting('block-1', at(thu, 10), at(thu, 11, 30)),
        ],
        taskDueDates: [thu, thu, fri],
        now: now,
      );

      final thursday = f.days.firstWhere((d) => d.day == thu);
      expect(thursday.meetingMinutes, 180);
      expect(thursday.blockedMinutes, 90);
      expect(thursday.landing.map((c) => c.emailId), ['blocked']);
      expect(thursday.tasksDue, 2);
      expect(thursday.capacityMinutes, 300);
      expect(thursday.demandMinutes, 90 + 2 * 30);
      expect(thursday.isOverloaded, isFalse);

      final friday = f.days.firstWhere((d) => d.day == fri);
      expect(friday.landing.map((c) => c.emailId), ['due-thu']);
      expect(friday.demandMinutes, 60 + 30);
      // Closed commitments never count.
      expect(f.days.every((d) => !d.landing.any((c) => c.emailId == 'closed')), isTrue);
    });

    test('a day is overloaded when demand exceeds what meetings leave', () {
      final f = forecast(
        commitments: [
          for (var i = 0; i < 3; i++) commitment(id: 'c$i', due: CommitmentDue.thisWeek),
        ],
        events: [meeting('m', at(fri, 9), at(fri, 15, 30))], // 6.5 h → 1.5 h left
        taskDueDates: const [],
        now: now,
      );
      final friday = f.days.firstWhere((d) => d.day == fri);
      expect(friday.capacityMinutes, 90);
      expect(friday.demandMinutes, 180);
      expect(friday.isOverloaded, isTrue);
      expect(friday.freeMinutes, -90);
      expect(f.overloaded.map((d) => d.day), [fri]);
      expect(f.plans, hasLength(1));
    });
  });

  group('rebalancing', () {
    test('moves the least urgent items to the freest day their deadline allows, '
        'into real free slots', () {
      final f = forecast(
        commitments: [
          // Three "this week" commitments land on Friday; Friday is nearly
          // full. Urgency decides who moves first: the calm ones.
          commitment(id: 'calm', due: CommitmentDue.thisWeek, urgency: 0),
          commitment(id: 'soon', due: CommitmentDue.thisWeek, urgency: 1),
          commitment(id: 'hot', due: CommitmentDue.thisWeek, urgency: 2),
          // A block already on Friday moves first of all.
          commitment(
            id: 'blocked',
            due: CommitmentDue.thisWeek,
            urgency: 2,
            scheduledStart: at(fri, 15, 30),
            scheduledEnd: at(fri, 16, 30),
            eventId: 'block-1',
          ),
        ],
        events: [
          meeting('fri', at(fri, 9), at(fri, 15, 30)),
          meeting('block-1', at(fri, 15, 30), at(fri, 16, 30)),
          // Today is gone, Wednesday is busy till 14:00, Thursday is clear
          // (and so is next Monday, but it is past the Friday deadline).
          meeting('tue', at(tue, 9), at(tue, 17)),
          meeting('wed', at(wed, 9), at(wed, 14)),
        ],
        taskDueDates: const [],
        now: now,
      );

      final plan = f.plans.single;
      expect(plan.day.day, fri);
      // Capacity 1.5 h; demand = 1 h block + 3 × 1 h = 4 h → 2.5 h over.
      expect(plan.day.demandMinutes - plan.day.capacityMinutes, 150);

      // The block goes first, then calm, then soon — three hours relieved
      // brings the day within capacity, so "hot" stays put.
      expect(plan.moves.map((m) => m.commitment.emailId), ['blocked', 'calm', 'soon']);
      expect(plan.relievedMinutes, 180);
      expect(plan.resolves, isTrue);

      // Thursday is the freest day, so everything lands there, each in its
      // own slot, none past the Friday deadline.
      for (final m in plan.moves) {
        expect(m.toStart.day, thu.day);
        expect(m.toStart.isBefore(fri), isTrue);
      }
      final starts = plan.moves.map((m) => m.toStart).toSet();
      expect(starts, hasLength(3));
      expect(plan.moves.first.from, at(fri, 15, 30));
      expect(plan.moves.first.isNewBlock, isFalse);
      expect(plan.moves.last.isNewBlock, isTrue);
    });

    test('an item due today on today cannot move; the plan says so', () {
      final f = forecast(
        commitments: [
          commitment(id: 'a', due: CommitmentDue.today),
          commitment(id: 'b', due: CommitmentDue.today),
        ],
        events: [meeting('m', at(tue, 9), at(tue, 16, 30))],
        taskDueDates: const [],
        now: now,
      );
      final plan = f.plans.single;
      expect(plan.day.day, tue);
      expect(plan.moves, isEmpty);
      expect(plan.resolves, isFalse);
    });
  });

  group('open slots', () {
    test('finds the gaps left in today and suggests the most pressing '
        'unscheduled commitment for each', () {
      final f = forecast(
        commitments: [
          commitment(id: 'later', due: CommitmentDue.later, urgency: 0),
          commitment(id: 'urgent', due: CommitmentDue.thisWeek, urgency: 2),
          commitment(
            id: 'overdue',
            due: CommitmentDue.today,
            urgency: 1,
            emailDate: now.subtract(const Duration(days: 2)),
          ),
          commitment(id: 'has-block', scheduledStart: at(wed, 9), scheduledEnd: at(wed, 10), eventId: 'e'),
        ],
        events: [
          meeting('a', at(tue, 9), at(tue, 10)),
          meeting('b', at(tue, 11), at(tue, 12)), // 10–11 is one hour free
          meeting('c', at(tue, 12, 15), at(tue, 16)), // 12–12:15 too short
          // 16–17 is free.
        ],
        taskDueDates: const [],
        now: DateTime(2026, 10, 6, 8, 50),
      );

      expect(f.openSlots.map((s) => (s.start, s.end)), [
        (at(tue, 10), at(tue, 11)),
        (at(tue, 16), at(tue, 17)),
      ]);
      // Overdue first, then the urgent one; the scheduled one never.
      expect(f.openSlots[0].suggestion?.emailId, 'overdue');
      expect(f.openSlots[1].suggestion?.emailId, 'urgent');
      expect(f.fillableSlot?.start, at(tue, 10));
      expect(f.openSlots.every((s) => !s.freed), isTrue);
    });

    test('a gap is "freed" when a meeting that filled it has vanished', () {
      final before = [
        meeting('standup', at(tue, 9), at(tue, 10)),
        meeting('review', at(tue, 10), at(tue, 11)),
        meeting('rest', at(tue, 11), at(tue, 17)),
      ];
      final after = [before[0], before[2]]; // the review was cancelled
      final f = forecast(
        commitments: [commitment(id: 'c', due: CommitmentDue.thisWeek)],
        events: after,
        taskDueDates: const [],
        now: DateTime(2026, 10, 6, 8, 50),
        previousEvents: before,
      );
      expect(f.openSlots.single.start, at(tue, 10));
      expect(f.openSlots.single.freed, isTrue);
      expect(f.openSlots.single.suggestion?.emailId, 'c');
    });

    test('nothing is open after the working day or on a weekend', () {
      expect(
        forecast(commitments: const [], events: const [], taskDueDates: const [], now: at(tue, 17, 30)).openSlots,
        isEmpty,
      );
      expect(
        forecast(commitments: const [], events: const [], taskDueDates: const [], now: DateTime(2026, 10, 10, 11)).openSlots,
        isEmpty,
      );
    });
  });
}
