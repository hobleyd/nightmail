import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_parser.dart';

String _ics(String dtstartLine) => '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
SUMMARY:Test meeting
$dtstartLine
DTEND;TZID=America/New_York:20260615T110000
END:VEVENT
END:VCALENDAR''';

void main() {
  group('IcsParser.parse DTSTART', () {
    test('UTC time (trailing Z) is taken verbatim as UTC', () {
      final event = IcsParser.parse(_ics('DTSTART:20260615T100000Z'));
      expect(event.start, DateTime.utc(2026, 6, 15, 10, 0, 0));
    });

    test('TZID zoned time is converted to the correct UTC instant', () {
      // 10:00 in America/New_York on 2026-06-15 is EDT (UTC-4) → 14:00 UTC.
      // This must be independent of the host machine's local timezone.
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=America/New_York:20260615T100000'),
      );
      expect(event.start.isUtc, isTrue);
      expect(event.start, DateTime.utc(2026, 6, 15, 14, 0, 0));
    });

    test('quoted TZID is resolved', () {
      final event = IcsParser.parse(
        _ics('DTSTART;TZID="America/New_York":20260615T100000'),
      );
      expect(event.start, DateTime.utc(2026, 6, 15, 14, 0, 0));
    });

    test('TZID during standard time uses the standard offset (EST, UTC-5)', () {
      // 2026-01-15 is outside US DST → EST (UTC-5) → 15:00 UTC.
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=America/New_York:20260115T100000'),
      );
      expect(event.start, DateTime.utc(2026, 1, 15, 15, 0, 0));
    });

    test('Windows/Outlook TZID name is mapped to IANA and converted', () {
      // "AUS Eastern Standard Time" → Australia/Sydney. On 2026-06-15 Sydney
      // is on standard time (AEST, UTC+10) → 10:00 local = 00:00 UTC.
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=AUS Eastern Standard Time:20260615T100000'),
      );
      expect(event.start, DateTime.utc(2026, 6, 15, 0, 0, 0));
    });

    test('Windows TZID with DST (Eastern Standard Time = America/New_York)',
        () {
      // The Windows name "Eastern Standard Time" covers both EST and EDT.
      // 2026-06-15 is EDT (UTC-4) → 10:00 local = 14:00 UTC.
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=Eastern Standard Time:20260615T100000'),
      );
      expect(event.start, DateTime.utc(2026, 6, 15, 14, 0, 0));
    });

    test('unresolvable TZID falls back to host-local wall-clock', () {
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=Nonexistent/Zone:20260615T100000'),
      );
      expect(event.start, DateTime(2026, 6, 15, 10, 0, 0).toUtc());
    });

    test('all-day VALUE=DATE is unaffected', () {
      final event = IcsParser.parse(
        _ics('DTSTART;VALUE=DATE:20260615'),
      );
      expect(event.isAllDay, isTrue);
      expect(event.start, DateTime.utc(2026, 6, 15));
    });
  });
}
