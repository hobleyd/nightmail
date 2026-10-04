import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/commitments/suggest_time_block.dart';

void main() {
  const suggest = SuggestTimeBlock(); // 9–17, 30-minute slots

  // Tuesday 6 October 2026, 09:00.
  final tue = DateTime(2026, 10, 6, 9);
  final wed = DateTime(2026, 10, 7);
  final thu = DateTime(2026, 10, 8);
  final fri = DateTime(2026, 10, 9);
  final nextMon = DateTime(2026, 10, 12);

  Commitment commitment({CommitmentDue due = CommitmentDue.none}) => Commitment(
        id: 'iOwe:s1',
        accountId: 'acc',
        emailId: 's1',
        kind: CommitmentKind.iOwe,
        status: CommitmentStatus.open,
        counterpart: const EmailAddress(address: 'sarah@client.com', name: 'Sarah'),
        subject: 'Migration numbers',
        snippet: '',
        due: due,
        urgency: 1,
        confidence: 0.9,
        emailDate: tue,
        detectedAt: tue,
      );

  CalendarEvent meeting(
    DateTime start,
    DateTime end, {
    String subject = 'Meeting',
    CalendarEventStatus status = CalendarEventStatus.busy,
    bool allDay = false,
  }) =>
      CalendarEvent(
        id: '$subject-${start.toIso8601String()}',
        subject: subject,
        start: start,
        end: end,
        isAllDay: allDay,
        status: status,
      );

  DateTime at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  group('candidate days', () {
    test('no deadline → the next five working days, skipping the weekend', () {
      final days = suggest.candidateDays(commitment: commitment(), now: tue);
      expect(days, [
        DateTime(2026, 10, 6),
        wed,
        thu,
        fri,
        nextMon,
      ]);
    });

    test('due today → today only while the working day has time left', () {
      expect(
        suggest.candidateDays(
          commitment: commitment(due: CommitmentDue.today),
          now: tue,
        ),
        [DateTime(2026, 10, 6)],
      );
      // At 16:45 nothing fits today any more: the next working day.
      expect(
        suggest.candidateDays(
          commitment: commitment(due: CommitmentDue.today),
          now: at(fri, 16, 45),
        ),
        [nextMon],
      );
    });

    test('this week → through Friday, never fewer than two days', () {
      expect(
        suggest.candidateDays(
          commitment: commitment(due: CommitmentDue.thisWeek),
          now: tue,
        ),
        [DateTime(2026, 10, 6), wed, thu, fri],
      );
      // Friday morning: Friday plus Monday.
      expect(
        suggest.candidateDays(
          commitment: commitment(due: CommitmentDue.thisWeek),
          now: at(fri, 9),
        ),
        [fri, nextMon],
      );
    });

    test('on a Saturday the horizon starts on Monday', () {
      final sat = DateTime(2026, 10, 10, 11);
      final days = suggest.candidateDays(commitment: commitment(), now: sat);
      expect(days.first, nextMon);
      expect(days.every((d) => d.weekday <= DateTime.friday), isTrue);
    });
  });

  group('load', () {
    test('counts busy minutes inside the working window, overlaps merged', () {
      final load = suggest.loadFor(wed, [
        meeting(at(wed, 9), at(wed, 11)),
        meeting(at(wed, 10), at(wed, 12)), // overlaps the first by an hour
        meeting(at(wed, 7), at(wed, 9, 30)), // only 30 min inside the window
        meeting(at(wed, 16), at(wed, 19)), // only 1 h inside the window
      ]);
      // 9–12 merged (180) + 9:00–9:30 overlaps that run → still 180,
      // plus 16–17 (60) = 240.
      expect(load.committedMinutes, 240);
      expect(load.workingMinutes, 480);
      expect(load.freeMinutes, 240);
      expect(load.load, 0.5);
    });

    test('free and all-day events are not load', () {
      final load = suggest.loadFor(wed, [
        meeting(at(wed, 9), at(wed, 12), status: CalendarEventStatus.free),
        meeting(wed, wed.add(const Duration(days: 1)), allDay: true),
      ]);
      expect(load.committedMinutes, 0);
    });
  });

  group('suggestion', () {
    final events = [
      meeting(at(tue, 9), at(tue, 12), subject: 'Tue am'),
      meeting(at(wed, 10), at(wed, 11), subject: 'Wed'),
      meeting(at(fri, 9), at(fri, 17), subject: 'Fri all day'),
    ];

    test('picks the lightest working day, earliest on a tie, at its first '
        'free slot', () {
      final s = suggest(commitment: commitment(), events: events, now: tue);

      // Thursday and next Monday are both clear; Thursday comes first.
      expect(s.start, at(thu, 9));
      expect(s.end, at(thu, 10));
      expect(s.hasConflict, isFalse);
      expect(s.reason, contains('Thursday'));
      expect(s.reason, contains('lightest'));
      expect(s.days.map((d) => d.day), [DateTime(2026, 10, 6), wed, thu, fri, nextMon]);
      // Only the horizon's meetings are handed back for drawing.
      expect(s.events.map((e) => e.subject), ['Tue am', 'Wed', 'Fri all day']);
    });

    test('with no length given the block is as long as the model\'s estimate, '
        'else an hour', () {
      expect(SuggestTimeBlock.durationFor(commitment()), const Duration(hours: 1));
      final sized = commitment().copyWith(estimatedMinutes: 120);
      expect(SuggestTimeBlock.durationFor(sized), const Duration(hours: 2));

      final s = suggest(commitment: sized, events: events, now: tue);
      expect(s.start, at(thu, 9));
      expect(s.end, at(thu, 11));

      // A quarter-hour estimate still starts on the slot grid.
      final quick = suggest(
        commitment: commitment().copyWith(estimatedMinutes: 15),
        events: events,
        now: tue,
      );
      expect(quick.end.difference(quick.start), const Duration(minutes: 15));
      expect(quick.start.minute % 30, 0);
    });

    test('due today → the first free slot today after now, on the slot grid',
        () {
      final s = suggest(
        commitment: commitment(due: CommitmentDue.today),
        events: events,
        now: DateTime(2026, 10, 6, 9, 40),
      );
      // Busy 9–12; now rounds up to 10:00 but the first free run is 12:00.
      expect(s.start, at(tue, 12));
      expect(s.hasConflict, isFalse);
      expect(s.reason, startsWith('Today'));
    });

    test('a longer block skips a day whose gaps are too short', () {
      final s = suggest(
        commitment: commitment(due: CommitmentDue.thisWeek),
        events: [
          // Tuesday: 9–12 busy, 12–13 free, 13–17 busy → no 2 h gap.
          meeting(at(tue, 9), at(tue, 12)),
          meeting(at(tue, 13), at(tue, 17)),
          // Wednesday: 9–15 busy → 15–17 free.
          meeting(at(wed, 9), at(wed, 15)),
          // Thursday and Friday heavier.
          meeting(at(thu, 9), at(thu, 16)),
          meeting(at(fri, 9), at(fri, 16, 30)),
        ],
        now: tue,
        duration: const Duration(hours: 2),
      );
      // Wednesday is lightest among the days with a 2 h gap.
      expect(s.start, at(wed, 15));
      expect(s.end, at(wed, 17));
    });

    test('with no free slot anywhere it opens the lightest day and says so',
        () {
      final s = suggest(
        commitment: commitment(due: CommitmentDue.today),
        events: [meeting(at(tue, 9), at(tue, 17))],
        now: tue,
      );
      expect(s.hasConflict, isTrue);
      expect(s.start, at(tue, 9));
      expect(s.reason, contains('No free'));
    });
  });

  group('manual choice helpers', () {
    test('slotFor finds the first free run on the chosen day', () {
      final start = suggest.slotFor(
        day: wed,
        events: [meeting(at(wed, 9), at(wed, 10, 30))],
        now: tue,
        duration: const Duration(minutes: 60),
      );
      expect(start, at(wed, 10, 30));
    });

    test('slotFor falls back to the working start when the day is full', () {
      final start = suggest.slotFor(
        day: wed,
        events: [meeting(at(wed, 9), at(wed, 17))],
        now: tue,
        duration: const Duration(minutes: 60),
      );
      expect(start, at(wed, 9));
    });

    test('conflicts reports overlap with busy meetings only', () {
      final busy = [meeting(at(wed, 10), at(wed, 11))];
      expect(suggest.conflicts(at(wed, 10, 30), at(wed, 11, 30), busy), isTrue);
      expect(suggest.conflicts(at(wed, 11), at(wed, 12), busy), isFalse);
      expect(
        suggest.conflicts(
          at(wed, 10),
          at(wed, 11),
          [meeting(at(wed, 10), at(wed, 11), status: CalendarEventStatus.free)],
        ),
        isFalse,
      );
    });
  });
}
