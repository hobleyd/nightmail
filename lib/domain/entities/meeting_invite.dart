enum MeetingInviteResponseType { accept, tentative, decline }

enum MeetingEmailType { invitation, cancellation, declineNotification }

class MeetingInvite {
  const MeetingInvite({
    this.icsData,
    this.meetingStart,
    this.type = MeetingEmailType.invitation,
  });

  /// Raw iCalendar text from a text/calendar MIME part. Populated for Gmail;
  /// null for O365 (Graph API handles responses via the message endpoint).
  final String? icsData;

  /// Start time of the meeting, populated from eventMessage.startDateTime for
  /// O365. Used as a calendar-search fallback when the message→event link fails.
  final DateTime? meetingStart;

  final MeetingEmailType type;
}
