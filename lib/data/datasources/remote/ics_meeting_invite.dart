import '../../../core/utils/ics_parser.dart';
import '../../../domain/entities/meeting_invite.dart';

/// Turns a `text/calendar` part into a [MeetingInvite].
///
/// Shared by the Gmail and Graph paths, which arrive here very differently:
/// Gmail classifies every calendar part it finds, while Graph classifies from
/// its own `meetingMessageType` and only falls back to the ICS for the one case
/// it has no word for — see `GraphApiDatasourceImpl.getEmail`. Both run inside
/// a parser isolate, so this stays a plain top-level function.
MeetingInvite buildMeetingInviteFromIcs(String icsData) {
  final type = icsInviteType(icsData);
  try {
    final event = IcsParser.parse(icsData);
    return MeetingInvite(
      icsData: icsData,
      type: type,
      uid: event.uid,
      // Carried only where an event may have to be created from scratch;
      // for the rest the provider already holds the meeting.
      summary: type == MeetingEmailType.publishedEvent ? event.summary : null,
      description:
          type == MeetingEmailType.publishedEvent ? event.description : null,
      meetingStart: event.start,
      meetingEnd: event.end,
      location: event.location,
      isAllDay: event.isAllDay,
      proposedStart:
          type == MeetingEmailType.proposedNewTime ? event.start : null,
      proposedEnd: type == MeetingEmailType.proposedNewTime ? event.end : null,
    );
  } catch (_) {
    // Method-only: the classification is what decides which banner appears, and
    // it survives a body that will not parse.
    return MeetingInvite(icsData: icsData, type: type);
  }
}

/// Classifies an iCalendar part by its `METHOD`.
///
/// `COUNTER` is an attendee proposing a different time for a meeting we
/// organize (RFC 5546 §3.2.7) — it must not fall through to
/// [MeetingEmailType.invitation], or
/// the organizer is offered Accept/Decline/Propose on their own meeting
/// instead of a way to act on the proposal.
///
/// `REPLY` is the same trap one step later: Google attaches the RSVP as
/// `invite.ics` to the "Accepted: …" mail it sends the organizer, so the
/// organizer was being offered Accept/Decline on a meeting they own and an
/// answer that has already been given. Every `PARTSTAT` goes to
/// [MeetingEmailType.responseNotification], declines included — Google cannot
/// cancel a meeting from a message id (`cancelMeetingFromEmail` throws), so the
/// Cancel meeting button [MeetingEmailType.declineNotification] carries would
/// have nothing behind it.
///
/// `PUBLISH` is an event sent as information — there is no RSVP to give, only
/// a copy to keep.
MeetingEmailType icsInviteType(String icsData) {
  return switch (icsMethod(icsData)) {
    'CANCEL' => MeetingEmailType.cancellation,
    'COUNTER' => MeetingEmailType.proposedNewTime,
    'REPLY' => MeetingEmailType.responseNotification,
    'PUBLISH' => MeetingEmailType.publishedEvent,
    _ => MeetingEmailType.invitation,
  };
}

/// Returns the METHOD value (e.g. 'REQUEST', 'CANCEL') from an iCalendar
/// string, upper-cased. Null when the part declares no method.
String? icsMethod(String icsData) {
  for (final rawLine in icsData.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.toUpperCase().startsWith('METHOD:')) {
      return line.substring('METHOD:'.length).trim().toUpperCase();
    }
  }
  return null;
}
