enum MeetingInviteResponseType { accept, tentative, decline }

enum MeetingEmailType { invitation, cancellation, declineNotification }

class MeetingInvite {
  const MeetingInvite({
    this.icsData,
    this.uid,
    this.meetingStart,
    this.meetingEnd,
    this.location,
    this.isAllDay = false,
    this.type = MeetingEmailType.invitation,
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
}
