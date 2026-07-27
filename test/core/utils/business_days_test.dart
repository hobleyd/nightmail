import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/business_days.dart';

void main() {
  // 8 Jun 2026 is a Monday, so the whole week is addressable by offset.
  DateTime monday([int hour = 14]) => DateTime(2026, 6, 8, hour);

  group('addBusinessDays', () {
    test('lands on the follow-up morning hour, not the time of day given', () {
      final result = addBusinessDays(monday(14), 1);

      expect(result.hour, followUpMorningHour);
      expect(result.minute, 0);
    });

    test('advances one weekday at a time', () {
      expect(addBusinessDays(monday(), 1).day, 9); // Tue
      expect(addBusinessDays(monday(), 2).day, 10); // Wed
      expect(addBusinessDays(monday(), 3).day, 11); // Thu
      expect(addBusinessDays(monday(), 4).day, 12); // Fri
    });

    test('skips the weekend', () {
      // Mon + 5 would be Saturday, so it lands on the following Monday.
      final result = addBusinessDays(monday(), 5);

      expect(result.weekday, DateTime.monday);
      expect(result.day, 15);
    });

    test('treats Friday + 1 as Monday', () {
      final friday = DateTime(2026, 6, 12, 16);

      final result = addBusinessDays(friday, 1);

      expect(result.weekday, DateTime.monday);
      expect(result.day, 15);
    });

    test('treats Saturday + 1 as Monday', () {
      final saturday = DateTime(2026, 6, 13, 10);

      final result = addBusinessDays(saturday, 1);

      expect(result.weekday, DateTime.monday);
      expect(result.day, 15);
    });

    test('treats Sunday + 1 as Monday', () {
      final sunday = DateTime(2026, 6, 14, 10);

      final result = addBusinessDays(sunday, 1);

      expect(result.weekday, DateTime.monday);
      expect(result.day, 15);
    });

    test('never returns a weekend day', () {
      var day = DateTime(2026, 6, 8);
      for (var i = 0; i < 30; i++) {
        day = DateTime(2026, 6, 8 + i);
        for (var count = 1; count <= 10; count++) {
          final result = addBusinessDays(day, count);
          expect(result.weekday, isNot(DateTime.saturday));
          expect(result.weekday, isNot(DateTime.sunday));
        }
      }
    });

    test('returns the same day at the follow-up hour for a count of zero', () {
      final result = addBusinessDays(monday(14), 0);

      expect(result, DateTime(2026, 6, 8, followUpMorningHour));
    });

    test('treats a negative count as zero', () {
      final result = addBusinessDays(monday(14), -3);

      expect(result, DateTime(2026, 6, 8, followUpMorningHour));
    });

    test('honours an explicit hour', () {
      final result = addBusinessDays(monday(), 1, atHour: 17);

      expect(result.hour, 17);
      expect(result.day, 9);
    });

    test('crosses a month boundary', () {
      // Tue 30 Jun 2026 + 2 business days -> Thu 2 Jul.
      final result = addBusinessDays(DateTime(2026, 6, 30), 2);

      expect(result.month, 7);
      expect(result.day, 2);
    });

    test('keeps the wall-clock hour across a daylight-saving transition', () {
      // Rebuilding a day at a time (rather than adding a Duration) is what
      // makes this hold; a 24h Duration would drift by an hour.
      for (var i = 0; i < 365; i++) {
        final from = DateTime(2026, 1, 1 + i);
        expect(addBusinessDays(from, 1).hour, followUpMorningHour,
            reason: 'drifted for $from');
      }
    });
  });
}
