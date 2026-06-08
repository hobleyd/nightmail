import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/email_date_formatter.dart';
import 'package:intl/intl.dart';

void main() {
  group('formatEmailDate', () {
    test('should format today date as time', () {
      final now = DateTime.now();
      final date = DateTime(now.year, now.month, now.day, 10, 30);
      expect(formatEmailDate(date), DateFormat('h:mm a').format(date));
    });

    test('should format yesterday date as weekday', () {
      final now = DateTime.now();
      final date = now.subtract(const Duration(days: 1));
      expect(formatEmailDate(date), DateFormat('EEE').format(date.toLocal()));
    });
  });

  group('formatEmailDateLong', () {
    test('should format date with time and timezone', () {
      final date = DateTime.parse('2026-06-08T10:00:00Z');
      final localDate = date.toLocal();
      final expected = '${DateFormat('EEE, MMM d, y \'at\' h:mm a').format(localDate)} (${localDate.timeZoneName})';
      expect(formatEmailDateLong(date), expected);
    });
  });
}
