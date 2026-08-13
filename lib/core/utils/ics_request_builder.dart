import 'ics_writer.dart';

/// Builds the `METHOD:REQUEST` iCalendar that carries a forwarded meeting.
///
/// This is the fallback half of forwarding an invitation. When the provider
/// can forward a meeting itself — Graph's `/events/{id}/forward`, or patching
/// a Google event the organizer lets guests invite to — the recipient becomes
/// a real attendee on the organizer's own copy and none of this is needed.
/// When it will not, the invitation is emailed from the forwarder's account
/// with this attached, which is what Outlook sends over SMTP for the same
/// action.
///
/// The point of a REQUEST rather than a `PUBLISH` (what "Add to calendar"
/// carries) is that the recipient can RSVP: their reply is addressed to
/// [organizerEmail], not to whoever forwarded it. Three properties do that
/// work and none is optional in practice —
///
/// - **[uid]** is the same UID every other attendee's copy carries, so the
///   organizer's client files the reply against the real meeting instead of
///   opening a second one, and the recipient's client recognises a later
///   update or cancellation from the organizer as being about this event.
/// - **[organizerEmail]** is where the RSVP goes. Without it a client either
///   refuses to offer Accept/Decline or sends the reply back to the sender of
///   the mail, who cannot act on it.
/// - **[sequence]** must be the invitation's own revision. A REQUEST claiming
///   a higher one would make the recipient's copy outrank the organizer's next
///   genuine update, which the client would then discard as stale.
///
/// [newAttendeeEmails] are written `RSVP=TRUE;PARTSTAT=NEEDS-ACTION` — they
/// are being asked. [existingAttendeeEmails] are listed without a status: who
/// else is coming is useful context, but their real answers live on the
/// organizer's copy and restating them here would be a guess.
String buildForwardRequestIcs({
  required String uid,
  required String summary,
  required DateTime start,
  required DateTime end,
  required bool isAllDay,
  required List<String> newAttendeeEmails,
  String? organizerEmail,
  String? organizerName,
  String? location,
  String? description,
  int? sequence,
  List<String> existingAttendeeEmails = const [],
  String? recurrenceRule,
  List<String> passthroughLines = const [],
  DateTime? now,
}) {
  final stamp = icsFormatUtc(now ?? DateTime.now());

  // Addresses are compared case-insensitively but written as given: a mailbox
  // is case-insensitive in practice, and listing somebody twice because one
  // copy is capitalised differently makes the recipient's client show a
  // duplicate guest.
  final seen = <String>{};
  final newAttendees = <String>[];
  for (final email in newAttendeeEmails) {
    final address = email.trim();
    if (address.isEmpty || !seen.add(address.toLowerCase())) continue;
    newAttendees.add(address);
  }
  final existingAttendees = <String>[];
  for (final email in existingAttendeeEmails) {
    final address = email.trim();
    if (address.isEmpty || !seen.add(address.toLowerCase())) continue;
    existingAttendees.add(address);
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
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    'UID:${icsEscape(uid)}',
    'SEQUENCE:${sequence ?? 0}',
    'DTSTAMP:$stamp',
    if (organizerEmail != null)
      'ORGANIZER${icsCnParam(organizerName)}:mailto:$organizerEmail',
    for (final email in newAttendees)
      'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:'
          'mailto:$email',
    for (final email in existingAttendees)
      'ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:$email',
    dtStart,
    dtEnd,
    'SUMMARY:${icsEscape(summary)}',
    if (location != null && location.trim().isNotEmpty)
      'LOCATION:${icsEscape(location.trim())}',
    if (description != null && description.trim().isNotEmpty)
      'DESCRIPTION:${icsEscape(description.trim())}',
    if (recurrenceRule != null && recurrenceRule.trim().isNotEmpty)
      recurrenceRule.trim(),
    // Echoed verbatim from the original — see [icsPassthroughLines]. Forwarding
    // one occurrence of a series must carry that occurrence's RECURRENCE-ID, or
    // the recipient is invited to the whole series instead.
    ...passthroughLines,
    'END:VEVENT',
    'END:VCALENDAR',
  ]);
}
