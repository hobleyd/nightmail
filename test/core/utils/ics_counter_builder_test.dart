import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_counter_builder.dart';

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

/// The counter's properties, keyed by name (parameters stripped), after
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

String _counter({
  String originalIcs = _invite,
  String attendeeEmail = 'sam@example.com',
  String? attendeeName = 'Sam Patel',
  String? comment,
}) =>
    buildCounterIcs(
      originalIcs: originalIcs,
      attendeeEmail: attendeeEmail,
      attendeeName: attendeeName,
      newStart: DateTime.utc(2026, 8, 5, 1, 30),
      newEnd: DateTime.utc(2026, 8, 5, 2, 0),
      comment: comment,
      now: DateTime.utc(2026, 7, 30, 4, 5, 6),
    );

void main() {
  group('buildCounterIcs', () {
    test('declares METHOD:COUNTER, not a REQUEST or REPLY', () {
      // The method is what makes Exchange read this as a proposed new time
      // rather than a plain RSVP — the whole point of the reply.
      expect(_counter(), contains('METHOD:COUNTER'));
      expect(_counter(), isNot(contains('METHOD:REQUEST')));
    });

    test('carries the proposed time as DTSTART/DTEND in UTC', () {
      final props = _properties(_counter());
      expect(props['DTSTART'], '20260805T013000Z');
      expect(props['DTEND'], '20260805T020000Z');
    });

    test('converts a local proposed time to UTC', () {
      final local = DateTime(2026, 8, 5, 11, 30);
      final ics = buildCounterIcs(
        originalIcs: _invite,
        attendeeEmail: 'sam@example.com',
        newStart: local,
        newEnd: local.add(const Duration(minutes: 30)),
      );
      final utc = local.toUtc();
      expect(
        _properties(ics)['DTSTART'],
        '${utc.year}${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}T'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}Z',
      );
    });

    test('echoes the invite UID and SEQUENCE so the organizer can match it',
        () {
      final props = _properties(_counter());
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
      expect(_properties(_counter(originalIcs: noSequence))['SEQUENCE'], '0');
    });

    test('addresses the organizer from the invite', () {
      expect(_unfold(_counter()),
          contains('ORGANIZER;CN="Dana Chen":mailto:dana@example.com'));
    });

    test('replies as the responding attendee, with PARTSTAT=DECLINED', () {
      // Declined, not tentative: the app declines the original invite when
      // proposing, so the counter must agree with the RSVP already sent.
      expect(
        _unfold(_counter()),
        contains('ATTENDEE;CN="Sam Patel";ROLE=REQ-PARTICIPANT;'
            'PARTSTAT=DECLINED;RSVP=FALSE:mailto:sam@example.com'),
      );
    });

    test('omits CN when the responder has no display name', () {
      expect(
        _unfold(_counter(attendeeName: null)),
        contains('ATTENDEE;ROLE=REQ-PARTICIPANT;'
            'PARTSTAT=DECLINED;RSVP=FALSE:mailto:sam@example.com'),
      );
    });

    test('keeps the summary and location', () {
      final props = _properties(_counter());
      expect(props['SUMMARY'], 'Quarterly review');
      expect(props['LOCATION'], 'Board room');
    });

    test('carries the note as COMMENT', () {
      expect(_properties(_counter(comment: 'Clashes with my flight'))['COMMENT'],
          'Clashes with my flight');
    });

    test('omits COMMENT for a blank note', () {
      expect(_properties(_counter(comment: '   ')).containsKey('COMMENT'),
          isFalse);
      expect(_properties(_counter()).containsKey('COMMENT'), isFalse);
    });

    test('escapes TEXT values', () {
      const tricky = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-3
SUMMARY:Budget; forecast, and 50\\50 split
DTSTART:20260803T230000Z
END:VEVENT
END:VCALENDAR''';
      // Semicolons and commas would otherwise read as property-value
      // separators and truncate the summary.
      expect(
        _properties(_counter(originalIcs: tricky))['SUMMARY'],
        r'Budget\; forecast\, and 50\\50 split',
      );
    });

    test('folds a newline in the note rather than breaking the property', () {
      final props = _properties(_counter(comment: 'Line one\nLine two'));
      expect(props['COMMENT'], r'Line one\nLine two');
    });

    test('echoes RECURRENCE-ID verbatim for one occurrence of a series', () {
      const occurrence = '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:series-1
SEQUENCE:0
SUMMARY:Stand-up
RECURRENCE-ID;TZID=Australia/Brisbane:20260805T090000
DTSTART;TZID=Australia/Brisbane:20260805T090000
DTEND;TZID=Australia/Brisbane:20260805T091500
END:VEVENT
END:VCALENDAR''';
      expect(
        _unfold(_counter(originalIcs: occurrence)),
        contains('RECURRENCE-ID;TZID=Australia/Brisbane:20260805T090000'),
      );
    });

    test('uses CRLF line endings and terminates the calendar', () {
      final ics = _counter();
      expect(ics, endsWith('END:VCALENDAR\r\n'));
      expect(ics.contains('\n\n'), isFalse);
      // Every LF must be part of a CRLF pair.
      for (var i = 0; i < ics.length; i++) {
        if (ics[i] == '\n') expect(i > 0 && ics[i - 1] == '\r', isTrue);
      }
    });

    test('stamps DTSTAMP from the supplied clock', () {
      expect(_properties(_counter())['DTSTAMP'], '20260730T040506Z');
    });

    test('folds content lines at 75 octets', () {
      final longSummary = 'x' * 200;
      final ics = _counter(
        originalIcs: '''
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-4
SUMMARY:$longSummary
DTSTART:20260803T230000Z
END:VEVENT
END:VCALENDAR''',
      );
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75),
            reason: 'unfolded line exceeds 75 octets: $line');
      }
      // Folding must be reversible: unfolding restores the whole summary.
      expect(_properties(ics)['SUMMARY'], longSummary);
    });

    test('never splits a multi-byte character across a fold', () {
      // 60 × 3 octets, so the COMMENT line must fold even though it is only 60
      // characters long — the limit is octets, not characters.
      final ics = _counter(comment: '→' * 60);
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
        // Each line must be valid UTF-8 on its own: a mid-character split
        // decodes to a replacement char, not the original.
        expect(utf8.decode(utf8.encode(line)), line);
      }
      expect(ics, contains('\r\n '), reason: 'expected the comment to fold');
      expect(_properties(ics)['COMMENT'], '→' * 60);
    });
  });
}
