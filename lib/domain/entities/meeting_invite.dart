enum MeetingInviteResponseType { accept, tentative, decline }

class MeetingInvite {
  const MeetingInvite({this.icsData});

  /// Raw iCalendar text from a text/calendar MIME part. Populated for Gmail;
  /// null for O365 (Graph API handles responses via the message endpoint).
  final String? icsData;
}
