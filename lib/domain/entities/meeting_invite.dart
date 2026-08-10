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

  /// An attendee's RSVP arriving back at the organizer — a `METHOD:REPLY` part,
  /// "Accepted: …"/"Declined: …" from Google Calendar. The recipient has
  /// nothing to respond to (the meeting is already theirs), so this draws no
  /// banner; it exists so a reply is not mistaken for an [invitation].
  ///
  /// Graph reaches the same outcome by a different route: it reports these as
  /// `meetingAccepted`/`meetingTentativelyAccepted`, which
  /// `EmailModel._parseMeetingInvite` maps to no invite at all. Only
  /// `meetingDeclined` is singled out, because Outlook can cancel a meeting
  /// from the notification and Google cannot.
  responseNotification,

  /// A `METHOD:PUBLISH` part — an event handed over as information, not as an
  /// invitation: a booking confirmation, a ticket, a fixture list. Nobody is
  /// waiting on an answer (there is usually no `ORGANIZER` to answer to), so
  /// the only useful action is to copy it onto the user's own calendar.
  ///
  /// An iCalendar part with no `METHOD` at all stays [invitation]. RFC 5545
  /// says an absent method means the object is not an iTIP message, which
  /// argues for treating it this way too — but plenty of senders omit it on a
  /// genuine request, and losing the Accept button on a real invitation is the
  /// worse of the two mistakes.
  publishedEvent,
}

class MeetingInvite {
  const MeetingInvite({
    this.icsData,
    this.uid,
    this.summary,
    this.description,
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

  /// The event's own title and body, from the ICS `SUMMARY` and `DESCRIPTION`.
  /// Set only where an event may have to be *created* from the invite —
  /// [MeetingEmailType.publishedEvent] — since every other type acts on a
  /// meeting the provider already knows about. Null for O365 eventMessages.
  final String? summary;
  final String? description;

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
