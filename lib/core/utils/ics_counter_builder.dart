import 'dart:convert';

import 'ics_parser.dart';

/// Builds an iCalendar `METHOD:COUNTER` reply — the interoperable way to
/// propose a new time for someone else's meeting (RFC 5546 §3.2.7).
///
/// Only Microsoft Graph has a native propose-new-time API. For every other
/// account type (Google, CalDAV, EventKit) the app declines the invite and
/// emails the organizer this COUNTER instead, which is what Outlook itself
/// sends over SMTP. Exchange and Outlook recognise it and offer the organizer
/// an "Accept Proposal" action; clients that don't understand COUNTER still
/// show the accompanying message body, which states the proposed time in
/// plain text.
///
/// [originalIcs] is the invite's own iCalendar text — the counter must echo its
/// `UID`, `SEQUENCE`, `ORGANIZER` and (for one occurrence of a series) its
/// `RECURRENCE-ID` so the organizer's client can match the reply to the
/// meeting it is about.
String buildCounterIcs({
  required String originalIcs,
  required String attendeeEmail,
  required DateTime newStart,
  required DateTime newEnd,
  String? attendeeName,
  String? comment,
  DateTime? now,
}) {
  final event = IcsParser.parse(originalIcs);
  final stamp = _formatUtc((now ?? DateTime.now()).toUtc());

  final lines = <String>[
    'BEGIN:VCALENDAR',
    'PRODID:-//SharpBlue//NightMail//EN',
    'VERSION:2.0',
    'METHOD:COUNTER',
    'BEGIN:VEVENT',
    if (event.uid != null) 'UID:${_escape(event.uid!)}',
    'SEQUENCE:${event.sequence ?? 0}',
    'DTSTAMP:$stamp',
    if (event.organizer != null)
      'ORGANIZER${_cnParam(event.organizerName)}:mailto:${event.organizer}',
    'ATTENDEE${_cnParam(attendeeName)};ROLE=REQ-PARTICIPANT;'
        'PARTSTAT=DECLINED;RSVP=FALSE:mailto:$attendeeEmail',
    'DTSTART:${_formatUtc(newStart.toUtc())}',
    'DTEND:${_formatUtc(newEnd.toUtc())}',
    'SUMMARY:${_escape(event.summary)}',
    if (event.location != null) 'LOCATION:${_escape(event.location!)}',
    // Echoed verbatim: a counter to one occurrence of a series must carry the
    // same RECURRENCE-ID, including its TZID/RANGE parameters, or the
    // organizer's client applies it to the wrong occurrence.
    ..._recurrenceIdLines(originalIcs),
    if (comment != null && comment.trim().isNotEmpty)
      'COMMENT:${_escape(comment.trim())}',
    'END:VEVENT',
    'END:VCALENDAR',
  ];

  // RFC 5545 requires CRLF line endings and lines folded at 75 octets.
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

/// `;CN="Name"` when a display name is known, else the empty string.
String _cnParam(String? name) {
  if (name == null || name.trim().isEmpty) return '';
  // Quoted-string parameter values cannot themselves contain a double quote.
  return ';CN="${name.trim().replaceAll('"', "'")}"';
}

List<String> _recurrenceIdLines(String originalIcs) {
  final unfolded = originalIcs.replaceAll(RegExp(r'\r?\n[ \t]'), '');
  return unfolded
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.toUpperCase().startsWith('RECURRENCE-ID'))
      .toList();
}

String _formatUtc(DateTime dt) {
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${p(dt.year, 4)}${p(dt.month)}${p(dt.day)}'
      'T${p(dt.hour)}${p(dt.minute)}${p(dt.second)}Z';
}

/// Escapes a TEXT value per RFC 5545 §3.3.11.
String _escape(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r\n', '\\n')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\n');

/// Folds a content line to 75 octets, continuing with a leading space.
///
/// Measures UTF-8 octets, not characters, and never splits a multi-byte
/// character across the fold — a receiver rejoins the octets before decoding,
/// so a split would corrupt the character.
String _fold(String line) {
  const limit = 75;
  if (utf8.encode(line).length <= limit) return line;

  final out = StringBuffer();
  var lineBytes = 0;
  for (final rune in line.runes) {
    final charBytes = _utf8Length(rune);
    if (lineBytes + charBytes > limit) {
      out.write('\r\n ');
      // The leading space of a folded line counts toward its own 75 octets.
      lineBytes = 1;
    }
    out.write(String.fromCharCode(rune));
    lineBytes += charBytes;
  }
  return out.toString();
}

int _utf8Length(int rune) {
  if (rune < 0x80) return 1;
  if (rune < 0x800) return 2;
  if (rune < 0x10000) return 3;
  return 4;
}
