enum MeetingInviteResponseType { accept, tentative, decline }

enum MeetingEmailType {
  invitation,
  cancellation,
  declineNotification,

  /// An attendee declined *and* proposed a different time — what the organizer
  /// receives from Outlook's propose-new-time, and from the `METHOD:COUNTER`
  /// reply this app sends for providers with no native equivalent. Distinct
  /// from [declineNotification] because there is a time to accept, not just a
  /// meeting to cancel.
  proposedNewTime,
}

class MeetingInvite {
  const MeetingInvite({
    this.icsData,
    this.uid,
    this.meetingStart,
    this.meetingEnd,
    this.location,
    this.isAllDay = false,
    this.type = MeetingEmailType.invitation,
    this.proposedStart,
    this.proposedEnd,
  });

  /// Raw iCalendar text from a text/calendar MIME part. Populated for Gmail;
  /// null for O365 (Graph API handles responses via the message endpoint).
  final String? icsData;

  /// The iCalendar UID of the meeting, from the ICS `UID` property. Matches
  /// [CalendarEvent.iCalUid] on the copy the provider auto-adds to the
  /// calendar, so conflict detection can tell that copy apart from a real
  /// clash. Null for O365 (no ICS part) and for unparseable ICS.
  final String? uid;

  /// Start time of the meeting (UTC). Parsed from icsData for Gmail;
  /// from eventMessage.startDateTime for O365.
  final DateTime? meetingStart;

  /// End time of the meeting (UTC). Parsed from icsData for Gmail;
  /// from eventMessage.endDateTime for O365.
  final DateTime? meetingEnd;

  /// Meeting location or room name, if provided.
  final String? location;

  /// True if this is an all-day event.
  final bool isAllDay;

  final MeetingEmailType type;

  /// The time an attendee proposed instead (UTC), set only for
  /// [MeetingEmailType.proposedNewTime]. From Graph's `proposedNewTime` slot,
  /// or the `DTSTART`/`DTEND` of a `METHOD:COUNTER` part.
  ///
  /// Note this is *not* [meetingStart]: for a counter arriving as ICS the two
  /// coincide, because the counter states only the proposed time and the
  /// original is not recoverable from it.
  final DateTime? proposedStart;
  final DateTime? proposedEnd;
}
