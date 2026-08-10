import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_parser.dart';
import 'package:timezone/timezone.dart' as tz;

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

    test('TZID result is a plain DateTime, not a TZDateTime', () {
      // Regression: returning a tz.TZDateTime made DateTime.toLocal() convert
      // against the timezone package's tz.local (UTC by default) instead of
      // the OS zone, so an 11am AEST meeting rendered as 1am (its UTC value).
      final event = IcsParser.parse(
        _ics('DTSTART;TZID=Australia/Brisbane:20260723T110000'),
      );
      // 11:00 Brisbane (UTC+10) → 01:00 UTC.
      expect(event.start, DateTime.utc(2026, 7, 23, 1, 0));
      expect(event.start, isNot(isA<tz.TZDateTime>()));
      expect(event.start.isUtc, isTrue);
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

  group('IcsParser.parse ORGANIZER', () {
    String organizerIcs(String organizerLine) => '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
SUMMARY:Test meeting
$organizerLine
DTSTART:20260615T100000Z
END:VEVENT
END:VCALENDAR''';

    test('address comes from the mailto: value', () {
      final event =
          IcsParser.parse(organizerIcs('ORGANIZER:mailto:dana@example.com'));
      expect(event.organizer, 'dana@example.com');
    });

    test('quoted CN is read as the display name', () {
      final event = IcsParser.parse(
        organizerIcs('ORGANIZER;CN="Dana Chen":mailto:dana@example.com'),
      );
      expect(event.organizerName, 'Dana Chen');
      expect(event.organizer, 'dana@example.com');
    });

    test('unquoted CN is read as the display name', () {
      final event = IcsParser.parse(
        organizerIcs('ORGANIZER;CN=Dana:mailto:dana@example.com'),
      );
      expect(event.organizerName, 'Dana');
    });

    test('CN is null when the parameter is absent', () {
      final event =
          IcsParser.parse(organizerIcs('ORGANIZER:mailto:dana@example.com'));
      expect(event.organizerName, isNull);
    });

    test('other ORGANIZER parameters do not become the name', () {
      final event = IcsParser.parse(organizerIcs(
        'ORGANIZER;SENT-BY="mailto:pa@example.com":mailto:dana@example.com',
      ));
      expect(event.organizer, 'dana@example.com');
      expect(event.organizerName, isNull);
    });

    test('organizer is null when the property is missing', () {
      final event = IcsParser.parse(_ics('DTSTART:20260615T100000Z'));
      expect(event.organizer, isNull);
    });
  });

  group('IcsParser.parse SEQUENCE', () {
    test('is read as an int', () {
      final event = IcsParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
SEQUENCE:4
DTSTART:20260615T100000Z
END:VEVENT
END:VCALENDAR''');
      expect(event.sequence, 4);
    });

    test('is null when absent, so callers can apply the RFC default of 0', () {
      final event = IcsParser.parse(_ics('DTSTART:20260615T100000Z'));
      expect(event.sequence, isNull);
    });
  });

  group('IcsParser.parse TEXT values', () {
    IcsEvent parseWith(List<String> lines) => IcsParser.parse('''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
DTSTART:20260615T100000Z
${lines.join('\n')}
END:VEVENT
END:VCALENDAR''');

    test('DESCRIPTION is read, with its escaped line breaks restored', () {
      final event = parseWith([r'DESCRIPTION:Bring a stand.\nDoors at 6.']);
      expect(event.description, 'Bring a stand.\nDoors at 6.');
    });

    test('DESCRIPTION is null when absent or empty, never an empty string', () {
      expect(parseWith(const []).description, isNull);
      expect(parseWith(['DESCRIPTION:']).description, isNull);
    });

    test('an escaped comma in a location is not part of the text', () {
      // Every LOCATION with a comma in it arrives this way, so unescaped the
      // room picker and the event form both show the backslash.
      final event = parseWith([r'LOCATION:Level 3\, Building A']);
      expect(event.location, 'Level 3, Building A');
    });

    test('an escaped backslash does not turn the next letter into an escape',
        () {
      // `\\n` is a backslash followed by the letter n — not a line break.
      final event = parseWith([r'SUMMARY:Path C:\\name']);
      expect(event.summary, r'Path C:\name');
    });

    test('a backslash before an undefined escape is left alone', () {
      final event = parseWith([r'SUMMARY:50\% off']);
      expect(event.summary, r'50\% off');
    });
  });
}
