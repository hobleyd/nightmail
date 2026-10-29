// MeetingReminderBoard decides what the single meeting-reminders dialog shows:
// each meeting at the latest alert of its countdown, from its first alert until
// it ends, and when a new alert should bring the dialog forward. Driven by a
// fake clock; the board is never started, so it never reads the setting off
// disk and is enabled by default.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/infrastructure/notifications/meeting_reminder_board.dart';

void main() {
  final start = DateTime.utc(2026, 10, 29, 10);

  CalendarEventModel event(
    String id, {
    DateTime? at,
    int? reminderMinutes = 15,
    Duration length = const Duration(minutes: 30),
  }) {
    final s = at ?? start;
    return CalendarEventModel(
      id: id,
      subject: 'Event $id',
      start: s,
      end: s.add(length),
      isAllDay: false,
      reminderMinutes: reminderMinutes,
    );
  }

  List<int> offsetsAt(List<CalendarEventModel> events, DateTime now) => [
        for (final r in MeetingReminderBoard.rowsAt({'a': events}, now))
          r.minutesUntilStart,
      ];

  group('rowsAt', () {
    test('a 15-minute reminder steps 15, 10, 5, 0 and lasts briefly past the '
        'start', () {
      final e = [event('1')];
      DateTime at(int minutes) => start.add(Duration(minutes: minutes));
      expect(offsetsAt(e, at(-16)), isEmpty);
      expect(offsetsAt(e, at(-15)), [15]);
      expect(offsetsAt(e, at(-11)), [15]);
      expect(offsetsAt(e, at(-10)), [10]);
      expect(offsetsAt(e, at(-5)), [5]);
      expect(offsetsAt(e, at(0)), [0]);
      expect(offsetsAt(e, at(9)), [0]);
      expect(offsetsAt(e, at(10)), isEmpty,
          reason: 'a meeting long under way is not announced on launch');
    });

    test('a meeting shorter than the grace leaves when it ends', () {
      final e = [event('1', length: const Duration(minutes: 5))];
      expect(offsetsAt(e, start.add(const Duration(minutes: 4))), [0]);
      expect(offsetsAt(e, start.add(const Duration(minutes: 5))), isEmpty);
    });

    test('an all-day or multi-day event never appears', () {
      // Outlook's all-day default is an 18-hour lead: a countdown to midnight.
      final allDay = CalendarEventModel(
        id: 'ooo',
        subject: 'Conference',
        start: start,
        end: start.add(const Duration(days: 3)),
        isAllDay: true,
        reminderMinutes: 1080,
      );
      for (final minutes in [-1080, -15, 0, 60 * 24]) {
        expect(offsetsAt([allDay], start.add(Duration(minutes: minutes))),
            isEmpty);
      }
    });

    test('a longer lead time holds its own alert until the countdown starts',
        () {
      final e = [event('1', reminderMinutes: 60)];
      expect(offsetsAt(e, start.subtract(const Duration(minutes: 60))), [60]);
      expect(offsetsAt(e, start.subtract(const Duration(minutes: 20))), [60]);
      expect(offsetsAt(e, start.subtract(const Duration(minutes: 15))), [15]);
    });

    test('a meeting without a reminder never appears', () {
      expect(offsetsAt([event('1', reminderMinutes: null)], start), isEmpty);
    });

    test('rows from every account are soonest first', () {
      final rows = MeetingReminderBoard.rowsAt({
        'a': [event('late', at: start.add(const Duration(minutes: 5)))],
        'b': [event('early')],
      }, start);
      expect([for (final r in rows) r.eventId], ['early', 'late']);
    });
  });

  group('board', () {
    late DateTime now;
    late MeetingReminderBoard board;
    late List<MeetingReminderUpdate> updates;
    late StreamSubscription<MeetingReminderUpdate> sub;

    setUp(() {
      now = start.subtract(const Duration(minutes: 15));
      board = MeetingReminderBoard(settings: AppSettings(), clock: () => now);
      updates = [];
      sub = board.updates.listen(updates.add);
    });

    tearDown(() => sub.cancel());

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('alerts on each new step, and only then', () async {
      board.update({'a': [event('1')]}, known: {'a'});
      await settle();
      expect(updates.single.alert, isTrue);
      expect(updates.single.rows.single.minutesUntilStart, 15);

      now = now.add(const Duration(minutes: 2));
      board.recompute();
      await settle();
      expect(updates, hasLength(1), reason: 'nothing changed');

      now = start.subtract(const Duration(minutes: 10));
      board.recompute();
      await settle();
      expect(updates.last.alert, isTrue);
      expect(updates.last.rows.single.minutesUntilStart, 10,
          reason: 'the newer alert replaces the older one');
    });

    test('a wake past several steps shows only the latest, once', () async {
      board.update({'a': [event('1')]}, known: {'a'});
      now = start.subtract(const Duration(minutes: 1));
      board.recompute();
      await settle();
      expect(updates, hasLength(2));
      expect(updates.last.rows.single.minutesUntilStart, 5);
    });

    test('a dismissal lasts until the next alert of that meeting', () async {
      board.update({'a': [event('1')]}, known: {'a'});
      board.dismiss(board.rows.single.id);
      await settle();
      expect(updates.last.rows, isEmpty);
      expect(updates.last.alert, isFalse);

      now = start.subtract(const Duration(minutes: 10));
      board.recompute();
      await settle();
      expect(updates.last.alert, isTrue);
      expect(updates.last.rows.single.minutesUntilStart, 10);
    });

    test('the row leaves after the meeting starts, without an alert',
        () async {
      board.update({'a': [event('1')]}, known: {'a'});
      now = start.add(MeetingReminderBoard.startedGrace);
      board.recompute();
      await settle();
      expect(updates.last.rows, isEmpty);
      expect(updates.last.alert, isFalse);
    });

    test('a failed fetch keeps the account; a removed account goes', () {
      board.update({'a': [event('1')], 'b': [event('2')]}, known: {'a', 'b'});
      board.update({'a': [event('1')]}, known: {'a', 'b'});
      expect(board.rows, hasLength(2), reason: 'b failed to fetch');
      board.update({'a': [event('1')]}, known: {'a'});
      expect([for (final r in board.rows) r.eventId], ['1']);
    });

    test('a started meeting outlives a fetch that no longer lists it', () {
      board.update({'a': [event('1'), event('2', at: start.add(const Duration(minutes: 5)))]},
          known: {'a'});
      now = start.add(const Duration(minutes: 1));
      board.update({'a': []}, known: {'a'});
      expect([for (final r in board.rows) r.eventId], ['1'],
          reason: 'only the meeting not yet started was cancelled');
    });

    test('a moved meeting comes back after a dismissal', () {
      board.update({'a': [event('1')]}, known: {'a'});
      board.dismiss(board.rows.single.id);
      board.update(
          {'a': [event('1', at: start.subtract(const Duration(minutes: 3)))]},
          known: {'a'});
      expect(board.rows.single.minutesUntilStart, 15);
    });

    test('turning the setting off empties the dialog; on again does not alert',
        () async {
      board.update({'a': [event('1')]}, known: {'a'});
      board.setEnabled(false);
      await settle();
      expect(updates.last.rows, isEmpty);
      board.setEnabled(true);
      await settle();
      expect(updates.last.rows, hasLength(1));
      expect(updates.last.alert, isFalse);
    });
  });

  test('a row survives the trip between windows', () {
    final row = MeetingReminderBoard.rowsAt({'a': [event('1')]}, start).single;
    final back = MeetingReminderRow.listFromJson([row.toJson()]).single;
    expect(back.id, row.id);
    expect(back.title, row.title);
    expect(back.end, row.end);
  });
}
