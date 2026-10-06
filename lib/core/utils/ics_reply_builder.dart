import 'ics_parser.dart';
import 'ics_writer.dart';

/// Builds the `METHOD:REPLY` iCalendar that tells an organizer how this
/// account answered their invitation (RFC 5546 §3.2.3).
///
/// Sent by `CalendarRepositoryImpl.respondToMeetingInvite` for a **forwarded**
/// invitation: somebody passed the organizer's invitation on by email, this
/// account is not on its guest list, and so the provider holds no meeting to
/// RSVP to and nothing it could send would reach the organizer. This is what
/// Outlook and Gmail send over SMTP in the same situation, and what Exchange
/// and Google read back as "Accepted: …" — Outlook then offers the organizer to
/// add the sender to the attendee list, which is the only way updates to the
/// meeting will ever reach them.
///
/// [originalIcs] is the invitation's own iCalendar text. The reply must echo
/// its `UID`, `SEQUENCE` and `ORGANIZER`, and for one occurrence of a series
/// its `RECURRENCE-ID`, or the organizer's client cannot match the answer to
/// the meeting it is about. Exactly one `ATTENDEE` is listed — the one
/// replying — carrying [partStat]: `ACCEPTED`, `TENTATIVE` or `DECLINED`.
String buildReplyIcs({
  required String originalIcs,
  required String attendeeEmail,
  required String partStat,
  String? attendeeName,
  String? comment,
  DateTime? now,
}) {
  final event = IcsParser.parse(originalIcs);
  final stamp = icsFormatUtc(now ?? DateTime.now());

  final dtStart = event.isAllDay
      ? 'DTSTART;VALUE=DATE:${icsFormatDate(event.start)}'
      : 'DTSTART:${icsFormatUtc(event.start)}';
  final dtEnd = event.isAllDay
      ? 'DTEND;VALUE=DATE:${icsFormatDate(event.end)}'
      : 'DTEND:${icsFormatUtc(event.end)}';

  return icsDocument([
    'BEGIN:VCALENDAR',
    'PRODID:-//SharpBlue//NightMail//EN',
    'VERSION:2.0',
    'METHOD:REPLY',
    'BEGIN:VEVENT',
    if (event.uid != null) 'UID:${icsEscape(event.uid!)}',
    'SEQUENCE:${event.sequence ?? 0}',
    'DTSTAMP:$stamp',
    if (event.organizer != null)
      'ORGANIZER${icsCnParam(event.organizerName)}:mailto:${event.organizer}',
    'ATTENDEE${icsCnParam(attendeeName)};ROLE=REQ-PARTICIPANT;'
        'PARTSTAT=${partStat.toUpperCase()};RSVP=FALSE:mailto:$attendeeEmail',
    dtStart,
    dtEnd,
    // Omitted rather than defaulted: this goes back to the organizer, and
    // '(No title)' would read as a request to rename their meeting.
    if (event.summary != null) 'SUMMARY:${icsEscape(event.summary!)}',
    // Echoed verbatim: a reply about one occurrence of a series must carry the
    // same RECURRENCE-ID, including its TZID/RANGE parameters, or the
    // organizer's client files the answer against the whole series.
    ...icsPassthroughLines(originalIcs, const {'RECURRENCE-ID'}),
    if (comment != null && comment.trim().isNotEmpty)
      'COMMENT:${icsEscape(comment.trim())}',
    'END:VEVENT',
    'END:VCALENDAR',
  ]);
}
