import 'ics_writer.dart';

/// Builds the `METHOD:CANCEL` iCalendar that tells a guest they are no longer
/// invited to a meeting (RFC 5546 §3.2.5).
///
/// Sent by `CalendarRepositoryImpl` when a guest is removed from a Google
/// meeting. Google's API can only email every guest or none when the roster
/// changes, so the event is patched silently and the leavers are told this way
/// — the counterpart of [buildRequestIcs] for the newcomers. Graph cancels the
/// removed guests itself, so nothing here is reached for a Microsoft account.
///
/// Only the removed guests are listed. RFC 5546 uses exactly that shape for
/// "attendee removed": a CANCEL addressed to the people being taken off, naming
/// them alone, so their client withdraws the meeting without believing it has
/// been cancelled for everyone.
///
/// [sequence] is the organizer's current revision, not a bump. A client
/// discards a CANCEL claiming a *lower* `SEQUENCE` than the copy it holds as
/// stale, and every update the provider has emailed this guest carried the
/// provider's own number — so anything below it is ignored, and anything above
/// it is a revision the organizer's copy will never reach.
String buildCancelIcs({
  required String uid,
  required String summary,
  required DateTime start,
  required DateTime end,
  required bool isAllDay,
  required List<String> removedAttendeeEmails,
  String? organizerEmail,
  String? organizerName,
  int? sequence,
  String? recurrenceRule,
  DateTime? now,
}) {
  final stamp = icsFormatUtc(now ?? DateTime.now());

  final seen = <String>{};
  final removed = <String>[];
  for (final email in removedAttendeeEmails) {
    final address = email.trim();
    if (address.isEmpty || !seen.add(address.toLowerCase())) continue;
    removed.add(address);
  }

  final dtStart = isAllDay
      ? 'DTSTART;VALUE=DATE:${icsFormatDate(start)}'
      : 'DTSTART:${icsFormatUtc(start)}';
  final dtEnd = isAllDay
      ? 'DTEND;VALUE=DATE:${icsFormatDate(end)}'
      : 'DTEND:${icsFormatUtc(end)}';

  return icsDocument([
    'BEGIN:VCALENDAR',
    'PRODID:-//SharpBlue//NightMail//EN',
    'VERSION:2.0',
    'METHOD:CANCEL',
    'BEGIN:VEVENT',
    'UID:${icsEscape(uid)}',
    'SEQUENCE:${sequence ?? 0}',
    'DTSTAMP:$stamp',
    'STATUS:CANCELLED',
    if (organizerEmail != null)
      'ORGANIZER${icsCnParam(organizerName)}:mailto:$organizerEmail',
    for (final email in removed)
      'ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:$email',
    dtStart,
    dtEnd,
    'SUMMARY:${icsEscape(summary)}',
    if (recurrenceRule != null && recurrenceRule.trim().isNotEmpty)
      recurrenceRule.trim(),
    'END:VEVENT',
    'END:VCALENDAR',
  ]);
}
