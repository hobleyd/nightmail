/// How an invitation was answered — returned by
/// `CalendarRepository.respondToMeetingInvite`, because the two ways leave the
/// user in materially different positions and the banner has to say which.
enum MeetingResponseMode {
  /// The provider answered on the meeting the organizer invited this account
  /// to: the organizer's guest list shows the answer, and later changes or a
  /// cancellation reach this calendar.
  viaProvider,

  /// The invitation had been **forwarded** — this account is not on its guest
  /// list, so the provider held no meeting to answer. A private copy was kept
  /// on the calendar and the answer was emailed to the organizer as a
  /// `METHOD:REPLY`, which is what Outlook and Gmail send in the same case.
  ///
  /// What the user does not get is a place on the organizer's guest list:
  /// until the organizer acts on that reply, an update or cancellation of the
  /// meeting is not sent to them.
  emailedOrganizer,

  /// This account *is* on the guest list, but the provider never filed the
  /// meeting — Google, for an outside sender on a calendar that only adds
  /// invitations from known senders. Answered the same way as a forwarded one
  /// (a copy kept, a `METHOD:REPLY` emailed), which is what Gmail's own "add
  /// to calendar" does; the organizer already has this account on the guest
  /// list, so updates arrive as usual and there is nothing to warn about.
  emailedUnfiled,
}
