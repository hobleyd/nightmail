import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_request_builder.dart';

/// Unfolds the document and returns its content lines, so an assertion does not
/// have to know where a long line happened to be folded.
List<String> _lines(String ics) => ics
    .replaceAll(RegExp(r'\r\n[ \t]'), '')
    .split('\r\n')
    .where((l) => l.isNotEmpty)
    .toList();

String? _line(String ics, String property) =>
    _lines(ics).where((l) => l.startsWith(property)).firstOrNull;

void main() {
  String build({
    String uid = 'evt-1@example.com',
    String summary = 'Quarterly review',
    bool isAllDay = false,
    List<String> newAttendeeEmails = const ['ravi@example.com'],
    List<String> existingAttendeeEmails = const [],
    String? organizerEmail = 'dana@example.com',
    String? organizerName = 'Dana Chen',
    String? location,
    String? description,
    int? sequence = 2,
    String? recurrenceRule,
    List<String> passthroughLines = const [],
  }) =>
      buildForwardRequestIcs(
        uid: uid,
        summary: summary,
        start: DateTime.utc(2026, 8, 3, 23),
        end: DateTime.utc(2026, 8, 3, 23, 45),
        isAllDay: isAllDay,
        newAttendeeEmails: newAttendeeEmails,
        existingAttendeeEmails: existingAttendeeEmails,
        organizerEmail: organizerEmail,
        organizerName: organizerName,
        location: location,
        description: description,
        sequence: sequence,
        recurrenceRule: recurrenceRule,
        passthroughLines: passthroughLines,
        now: DateTime.utc(2026, 7, 30, 10, 15, 30),
      );

  test('is a METHOD:REQUEST with CRLF endings', () {
    final ics = build();

    expect(ics, contains('METHOD:REQUEST'));
    expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
    expect(ics, endsWith('END:VCALENDAR\r\n'));
  });

  test('carries the meeting\'s own UID and SEQUENCE, not fresh ones', () {
    // The whole point of forwarding as a REQUEST: the organizer's client has to
    // recognise the RSVP as being about this meeting, and a SEQUENCE above the
    // organizer's own would make their next real update look stale.
    final ics = build();

    expect(_line(ics, 'UID:'), 'UID:evt-1@example.com');
    expect(_line(ics, 'SEQUENCE:'), 'SEQUENCE:2');
  });

  test('defaults SEQUENCE to 0 when the invitation stated none', () {
    expect(_line(build(sequence: null), 'SEQUENCE:'), 'SEQUENCE:0');
  });

  test('addresses the RSVP to the organizer, not the forwarder', () {
    final ics = build();

    expect(
      _line(ics, 'ORGANIZER'),
      'ORGANIZER;CN="Dana Chen":mailto:dana@example.com',
    );
  });

  test('asks the new attendee to reply and merely lists the existing ones', () {
    final ics = build(
      newAttendeeEmails: const ['ravi@example.com'],
      existingAttendeeEmails: const ['sam@example.com'],
    );

    expect(
      _line(ics, 'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT'),
      'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:'
      'mailto:ravi@example.com',
    );
    // No PARTSTAT on an existing guest: their real answer lives on the
    // organizer's copy and restating it here would be a guess.
    expect(
      _lines(ics),
      contains('ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:sam@example.com'),
    );
  });

  test('lists someone already on the meeting once, whatever their casing', () {
    final ics = build(
      newAttendeeEmails: const ['Ravi@Example.com'],
      existingAttendeeEmails: const ['ravi@example.com', 'sam@example.com'],
    );

    final attendees = _lines(ics).where((l) => l.startsWith('ATTENDEE'));
    expect(attendees, hasLength(2));
    // The new-attendee spelling wins, so the person being invited is the one
    // asked to reply rather than being listed as an existing guest.
    expect(
      attendees.first,
      contains('RSVP=TRUE:mailto:Ravi@Example.com'),
    );
  });

  test('writes an all-day meeting as dates, not UTC instants', () {
    // A UTC date-time moves the day for every reader outside Greenwich.
    final ics = build(isAllDay: true);

    expect(_line(ics, 'DTSTART'), 'DTSTART;VALUE=DATE:20260803');
    expect(_line(ics, 'DTEND'), 'DTEND;VALUE=DATE:20260803');
  });

  test('writes a timed meeting as UTC instants', () {
    final ics = build();

    expect(_line(ics, 'DTSTART'), 'DTSTART:20260803T230000Z');
    expect(_line(ics, 'DTEND'), 'DTEND:20260803T234500Z');
    expect(_line(ics, 'DTSTAMP'), 'DTSTAMP:20260730T101530Z');
  });

  test('escapes text values', () {
    final ics = build(
      summary: 'Budget; Q3, final',
      location: r'Level 3\, Building A',
    );

    expect(_line(ics, 'SUMMARY:'), r'SUMMARY:Budget\; Q3\, final');
    expect(_line(ics, 'LOCATION:'), r'LOCATION:Level 3\\\, Building A');
  });

  test('omits location and description when there is nothing to say', () {
    final ics = build(location: '   ', description: null);

    expect(_lines(ics).any((l) => l.startsWith('LOCATION')), isFalse);
    expect(_lines(ics).any((l) => l.startsWith('DESCRIPTION')), isFalse);
  });

  test('carries the recurrence, so a series is not forwarded as one meeting',
      () {
    final ics = build(recurrenceRule: 'RRULE:FREQ=WEEKLY;BYDAY=MO');

    expect(_lines(ics), contains('RRULE:FREQ=WEEKLY;BYDAY=MO'));
  });

  test('copies passthrough lines through untouched', () {
    // A forwarded occurrence must keep the original RECURRENCE-ID verbatim,
    // parameters included, or it lands on the wrong occurrence.
    const recurrenceId = 'RECURRENCE-ID;TZID=Australia/Sydney:20260803T090000';
    final ics = build(passthroughLines: const [recurrenceId]);

    expect(_lines(ics), contains(recurrenceId));
  });

  test('folds a long line at 75 octets', () {
    final ics = build(summary: 'A' * 200);

    for (final line in ics.split('\r\n')) {
      expect(line.length, lessThanOrEqualTo(75));
    }
    expect(_line(ics, 'SUMMARY:'), 'SUMMARY:${'A' * 200}');
  });

  test('still builds when the meeting has no known organizer', () {
    // Providers without an organizer field (CalDAV, EventKit) reach here. The
    // recipient can add it to their calendar; there is simply nobody to RSVP to.
    final ics = build(organizerEmail: null, organizerName: null);

    expect(_lines(ics).any((l) => l.startsWith('ORGANIZER')), isFalse);
    expect(ics, contains('METHOD:REQUEST'));
  });
}
