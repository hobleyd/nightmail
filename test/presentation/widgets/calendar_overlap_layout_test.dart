import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/presentation/widgets/calendar_overlap_layout.dart';

CalendarEvent _event(
  String id, {
  required DateTime start,
  required DateTime end,
}) =>
    CalendarEvent(
      id: id,
      subject: id,
      start: start,
      end: end,
      isAllDay: false,
    );

/// Brisbane is UTC+10 year-round, matching the calendar payloads these cases
/// were taken from.
DateTime _bne(int day, int hour, int minute) =>
    DateTime.utc(2026, 7, day, hour, minute).subtract(const Duration(hours: 10));

void main() {
  group('computeOverlapLayout', () {
    test('gives a lone event the full width', () {
      final layout = computeOverlapLayout([
        _event('solo', start: _bne(28, 9, 0), end: _bne(28, 9, 30)),
      ]);

      expect(layout.single.index, 0);
      expect(layout.single.total, 1);
    });

    test('tiles two overlapping events into separate columns', () {
      final layout = computeOverlapLayout([
        _event('tech', start: _bne(28, 10, 0), end: _bne(28, 11, 0)),
        _event('avengers', start: _bne(28, 10, 15), end: _bne(28, 10, 30)),
      ]);

      expect(layout.map((s) => s.total), everyElement(2));
      expect(layout.map((s) => s.index), containsAll([0, 1]));
    });

    test('reuses a column for back-to-back events', () {
      final layout = computeOverlapLayout([
        _event('long', start: _bne(28, 9, 0), end: _bne(28, 10, 0)),
        _event('a', start: _bne(28, 9, 0), end: _bne(28, 9, 30)),
        _event('b', start: _bne(28, 9, 30), end: _bne(28, 10, 0)),
      ]);

      // Two columns total: the hour-long event, and a/b stacked in the second.
      expect(layout.map((s) => s.total), everyElement(2));
      expect(layout[1].index, layout[2].index);
      expect(layout[0].index, isNot(layout[1].index));
    });

    test('tiles a meeting against an event that runs past midnight', () {
      // Hotel booking 28th 14:00 → 29th 10:00, with a 1:1 inside it. The end
      // time-of-day (10:00) is *earlier* than the 1:1's start (15:00), which
      // used to collapse both into one full-width column.
      final layout = computeOverlapLayout([
        _event('hotel', start: _bne(28, 14, 0), end: _bne(29, 10, 0)),
        _event('1:1', start: _bne(28, 15, 0), end: _bne(28, 16, 0)),
      ]);

      expect(layout.map((s) => s.total), everyElement(2));
      expect(layout[0].index, isNot(layout[1].index));
    });

    test('tiles events that share an ID', () {
      // The same meeting arriving from two accounts must still get two columns.
      final layout = computeOverlapLayout([
        _event('dupe', start: _bne(28, 7, 5), end: _bne(28, 8, 15)),
        _event('dupe', start: _bne(28, 7, 5), end: _bne(28, 8, 15)),
      ]);

      expect(layout.map((s) => s.total), everyElement(2));
      expect(layout[0].index, isNot(layout[1].index));
    });

    test('keeps spans aligned with the input order, not start order', () {
      final layout = computeOverlapLayout([
        _event('later', start: _bne(28, 13, 30), end: _bne(28, 14, 0)),
        _event('earlier', start: _bne(28, 9, 0), end: _bne(28, 9, 30)),
      ]);

      // Disjoint events: each keeps the full width in its own cluster.
      expect(layout.map((s) => s.total), everyElement(1));
      expect(layout, hasLength(2));
    });
  });
}
