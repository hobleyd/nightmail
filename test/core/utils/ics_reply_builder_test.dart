import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_reply_builder.dart';

/// An invitation somebody forwarded on: the roster names the organizer and one
/// guest, and the account replying is on neither.
const _invite = '''
BEGIN:VCALENDAR
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:evt-1@example.com
SEQUENCE:3
SUMMARY:Quarterly review
LOCATION:Board room
ORGANIZER;CN="Dana Chen":mailto:dana@example.com
ATTENDEE;CN=Sam:mailto:sam@example.com
DTSTART:20260803T230000Z
DTEND:20260803T234500Z
END:VEVENT
END:VCALENDAR''';

/// Rejoins folded content lines, as a receiving client does before reading
/// properties. Assertions on a whole property line must go through this — a
/// line long enough to fold (e.g. ATTENDEE with a CN) is otherwise split.
String _unfold(String ics) => ics.replaceAll('\r\n ', '');

/// The reply's properties, keyed by name (parameters stripped), after
/// unfolding — the shape a receiving client sees.
Map<String, String> _properties(String ics) {
  final unfolded = _unfold(ics);
  final out = <String, String>{};
  for (final line in unfolded.split('\r\n')) {
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon == -1) continue;
    final name = line.substring(0, colon).split(';').first.toUpperCase();
    out[name] = line.substring(colon + 1);
  }
  return out;
}

String _reply({
  String originalIcs = _invite,
  String attendeeEmail = 'alex@example.com',
  String partStat = 'ACCEPTED',
  String? attendeeName = 'Alex Reed',
  String? comment,
}) =>
    buildReplyIcs(
      originalIcs: originalIcs,
      attendeeEmail: attendeeEmail,
      partStat: partStat,
      attendeeName: attendeeName,
      comment: comment,
      now: DateTime.utc(2026, 7, 30, 4, 5, 6),
    );

void main() {
  group('buildReplyIcs', () {
    test('declares METHOD:REPLY, not a REQUEST or COUNTER', () {
      // The method is what makes Exchange and Google read this as an answer
      // to the invitation rather than a new one.
      expect(_reply(), contains('METHOD:REPLY'));
      expect(_reply(), isNot(contains('METHOD:REQUEST')));
      expect(_reply(), isNot(contains('METHOD:COUNTER')));
    });

    test('echoes the invite UID and SEQUENCE so the organizer can match it',
        () {
      final props = _properties(_reply());
      expect(props['UID'], 'evt-1@example.com');
      expect(props['SEQUENCE'], '3');
    });

    test('defaults SEQUENCE to 0 when the invite omits it', () {
      const noSequence = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-2
SUMMARY:Chat
DTSTART:20260803T230000Z
END:VEVENT
END:VCALENDAR''';
      expect(_properties(_reply(originalIcs: noSequence))['SEQUENCE'], '0');
    });

    test('addresses the organizer from the invite', () {
      expect(_unfold(_reply()),
          contains('ORGANIZER;CN="Dana Chen":mailto:dana@example.com'));
    });

    test('lists only the replying attendee, with the answer as PARTSTAT', () {
      final unfolded = _unfold(_reply());
      expect(
        unfolded,
        contains('ATTENDEE;CN="Alex Reed";ROLE=REQ-PARTICIPANT;'
            'PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:alex@example.com'),
      );
      // The original roster is not restated: a REPLY is about one attendee,
      // and naming the others would be a guess at answers they gave elsewhere.
      expect(unfolded, isNot(contains('mailto:sam@example.com')));
    });

    test('carries TENTATIVE and DECLINED through unchanged', () {
      expect(_unfold(_reply(partStat: 'TENTATIVE')),
          contains('PARTSTAT=TENTATIVE;'));
      expect(_unfold(_reply(partStat: 'declined')),
          contains('PARTSTAT=DECLINED;'));
    });

    test('omits CN when the responder has no display name', () {
      expect(
        _unfold(_reply(attendeeName: null)),
        contains('ATTENDEE;ROLE=REQ-PARTICIPANT;'
            'PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:alex@example.com'),
      );
    });

    test('keeps the meeting time and title', () {
      final props = _properties(_reply());
      expect(props['DTSTART'], '20260803T230000Z');
      expect(props['DTEND'], '20260803T234500Z');
      expect(props['SUMMARY'], 'Quarterly review');
    });

    test('writes an all-day meeting as dates, not UTC midnights', () {
      const allDay = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-3
SUMMARY:Offsite
DTSTART;VALUE=DATE:20260810
DTEND;VALUE=DATE:20260811
END:VEVENT
END:VCALENDAR''';
      final unfolded = _unfold(_reply(originalIcs: allDay));
      expect(unfolded, contains('DTSTART;VALUE=DATE:20260810'));
      expect(unfolded, contains('DTEND;VALUE=DATE:20260811'));
    });

    test('carries the note as COMMENT', () {
      expect(_properties(_reply(comment: 'Happy to join'))['COMMENT'],
          'Happy to join');
    });

    test('omits COMMENT when there is no note', () {
      expect(_properties(_reply())['COMMENT'], isNull);
      expect(_properties(_reply(comment: '   '))['COMMENT'], isNull);
    });

    test('echoes RECURRENCE-ID for a reply to one occurrence', () {
      const occurrence = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:series-1
SUMMARY:Weekly
ORGANIZER:mailto:dana@example.com
DTSTART:20260910T010000Z
DTEND:20260910T020000Z
RECURRENCE-ID;TZID=Australia/Sydney:20260910T110000
END:VEVENT
END:VCALENDAR''';
      expect(
        _unfold(_reply(originalIcs: occurrence)),
        contains('RECURRENCE-ID;TZID=Australia/Sydney:20260910T110000'),
      );
    });

    test('uses CRLF line endings', () {
      expect(_reply(), contains('\r\n'));
      expect(_reply().replaceAll('\r\n', ''), isNot(contains('\n')));
    });
  });
}
