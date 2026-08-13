/// How a forwarded meeting actually reached its recipient.
///
/// The two are not interchangeable, and the difference is the recipient's
/// standing in the meeting rather than a detail of transport — so the UI says
/// which one happened rather than reporting a bare "Sent".
enum MeetingForwardMode {
  /// The provider forwarded it. The recipient is a real attendee on the
  /// organizer's own copy: their RSVP goes to the organizer, the organizer's
  /// guest list shows them, and a later change or cancellation reaches them.
  onBehalfOfOrganizer,

  /// The invitation was emailed from this account instead, because the
  /// provider would not do the above — see
  /// [MeetingForwardUnsupportedException].
  ///
  /// The attached `METHOD:REQUEST` still names the real organizer, so the
  /// recipient can put it in their calendar and RSVP to the right person. What
  /// they do not get is a place on the organizer's guest list: until the
  /// organizer acts on that RSVP, nobody else knows they were invited, and an
  /// update to the meeting will not be sent to them.
  fromMe,
}
