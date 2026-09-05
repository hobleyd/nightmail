import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ics_cancel_builder.dart';

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
    List<String> removedAttendeeEmails = const ['ravi@example.com'],
    String? organizerEmail = 'dana@example.com',
    String? organizerName = 'Dana Chen',
    int? sequence = 2,
    String? recurrenceRule,
  }) =>
      buildCancelIcs(
        uid: uid,
        summary: summary,
        start: DateTime.utc(2026, 8, 3, 23),
        end: DateTime.utc(2026, 8, 3, 23, 45),
        isAllDay: isAllDay,
        removedAttendeeEmails: removedAttendeeEmails,
        organizerEmail: organizerEmail,
        organizerName: organizerName,
        sequence: sequence,
        recurrenceRule: recurrenceRule,
        now: DateTime.utc(2026, 7, 30, 10, 15, 30),
      );

  test('is a cancelled METHOD:CANCEL with CRLF endings', () {
    final ics = build();

    expect(ics, contains('METHOD:CANCEL'));
    expect(_line(ics, 'STATUS:'), 'STATUS:CANCELLED');
    expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
    expect(ics, endsWith('END:VCALENDAR\r\n'));
  });

  test('carries the meeting\'s own UID and SEQUENCE', () {
    // The guest's client matches the cancellation to the copy it holds by UID,
    // and discards it as stale if the SEQUENCE is below that copy's.
    final ics = build();

    expect(_line(ics, 'UID:'), 'UID:evt-1@example.com');
    expect(_line(ics, 'SEQUENCE:'), 'SEQUENCE:2');
    expect(_line(ics, 'DTSTAMP:'), 'DTSTAMP:20260730T101530Z');
  });

  test('defaults SEQUENCE to 0 when the provider reports none', () {
    expect(_line(build(sequence: null), 'SEQUENCE:'), 'SEQUENCE:0');
  });

  test('names the organizer and lists only the removed guests', () {
    // RFC 5546 §3.2.5: a CANCEL for "attendee removed" is addressed to the
    // people being taken off and names them alone, so their client withdraws
    // the meeting without believing it was cancelled for everyone.
    final ics = build(
      removedAttendeeEmails: const ['ravi@example.com', 'Ravi@example.com'],
    );
    expect(_line(ics, 'ORGANIZER'),
        'ORGANIZER;CN="Dana Chen":mailto:dana@example.com');
    final attendees = _lines(ics).where((l) => l.startsWith('ATTENDEE'));
    expect(attendees, ['ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:ravi@example.com']);
  });

  test('writes all-day bounds as dates and timed ones as UTC instants', () {
    expect(_line(build(), 'DTSTART'), 'DTSTART:20260803T230000Z');
    expect(_line(build(), 'DTEND'), 'DTEND:20260803T234500Z');
    expect(_line(build(isAllDay: true), 'DTSTART'),
        'DTSTART;VALUE=DATE:20260803');
    expect(_line(build(isAllDay: true), 'DTEND'), 'DTEND;VALUE=DATE:20260803');
  });

  test('carries the series rule so the whole series is withdrawn', () {
    final ics = build(recurrenceRule: 'RRULE:FREQ=WEEKLY;BYDAY=TU');

    expect(_line(ics, 'RRULE:'), 'RRULE:FREQ=WEEKLY;BYDAY=TU');
    expect(_line(build(), 'RRULE:'), isNull);
  });

  test('escapes the summary', () {
    expect(_line(build(summary: 'Plan; review, part 1'), 'SUMMARY:'),
        r'SUMMARY:Plan\; review\, part 1');
  });
}
