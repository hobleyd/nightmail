import 'ics_parser.dart';
import 'ics_writer.dart';

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
  final stamp = icsFormatUtc(now ?? DateTime.now());

  return icsDocument([
    'BEGIN:VCALENDAR',
    'PRODID:-//SharpBlue//NightMail//EN',
    'VERSION:2.0',
    'METHOD:COUNTER',
    'BEGIN:VEVENT',
    if (event.uid != null) 'UID:${icsEscape(event.uid!)}',
    'SEQUENCE:${event.sequence ?? 0}',
    'DTSTAMP:$stamp',
    if (event.organizer != null)
      'ORGANIZER${icsCnParam(event.organizerName)}:mailto:${event.organizer}',
    'ATTENDEE${icsCnParam(attendeeName)};ROLE=REQ-PARTICIPANT;'
        'PARTSTAT=DECLINED;RSVP=FALSE:mailto:$attendeeEmail',
    'DTSTART:${icsFormatUtc(newStart)}',
    'DTEND:${icsFormatUtc(newEnd)}',
    'SUMMARY:${icsEscape(event.summary)}',
    if (event.location != null) 'LOCATION:${icsEscape(event.location!)}',
    // Echoed verbatim: a counter to one occurrence of a series must carry the
    // same RECURRENCE-ID, including its TZID/RANGE parameters, or the
    // organizer's client applies it to the wrong occurrence.
    ...icsPassthroughLines(originalIcs, const {'RECURRENCE-ID'}),
    if (comment != null && comment.trim().isNotEmpty)
      'COMMENT:${icsEscape(comment.trim())}',
    'END:VEVENT',
    'END:VCALENDAR',
  ]);
}

