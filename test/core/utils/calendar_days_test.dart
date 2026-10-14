import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/calendar_days.dart';

void main() {
  test('every day of a year steps to the next midnight, DST included', () {
    // Spans both clock changes in either hemisphere, whatever the zone the
    // tests run in: a 24-hour add would land on 1:00 or 23:00 the same day.
    var d = DateTime(2026, 1, 1);
    for (var i = 0; i < 366; i++) {
      final next = addCalendarDays(d, 1);
      expect([next.hour, next.minute], [0, 0], reason: '$d');
      expect(next.difference(d).inHours, inInclusiveRange(23, 25));
      expect(next.day == d.day, isFalse, reason: '$d repeated');
      d = next;
    }
    expect(d, DateTime(2027, 1, 2));
  });

  test('goes back across a month boundary', () {
    expect(addCalendarDays(DateTime(2026, 10, 1, 15), -3),
        DateTime(2026, 9, 28));
  });
}
