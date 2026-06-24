enum MeetingInviteResponseType { accept, tentative, decline }

enum MeetingEmailType { invitation, cancellation, declineNotification }

class MeetingInvite {
  const MeetingInvite({
    this.icsData,
    this.meetingStart,
    this.meetingEnd,
    this.location,
    this.isAllDay = false,
    this.type = MeetingEmailType.invitation,
  });

  /// Raw iCalendar text from a text/calendar MIME part. Populated for Gmail;
  /// null for O365 (Graph API handles responses via the message endpoint).
  final String? icsData;

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
