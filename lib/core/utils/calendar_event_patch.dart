import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/usecases/update_calendar_event.dart';

/// How a calendar mutation looks once applied, without asking the provider.
///
/// Two callers need to agree exactly here, which is why this is not a private
/// helper on either of them: `CalendarRepositoryImpl` applies a mutation to the
/// cache the moment the user makes it, and `CalendarPendingOpReconciler`
/// re-applies the same mutation on top of a server fetch that may have been
/// taken before the queued op reached the provider. If the two computed
/// different results, an optimistic change would visibly flicker back and forth.

/// The event as it will look once [response] has been sent.
///
/// The free/busy status moves in step with the RSVP because the calendar derives
/// conflicts from it: a meeting answered "tentative" has to stop reading as a
/// hard clash immediately.
///
/// A decline marks the event declined rather than removing it. Providers differ
/// on whether a declined meeting stays on your calendar, and the next sync
/// settles that without this having to guess — whereas guessing "removed" and
/// being wrong would drop a meeting the user still has.
CalendarEvent applyRsvp(
  CalendarEvent event,
  MeetingInviteResponseType response,
) =>
    switch (response) {
      MeetingInviteResponseType.accept => event.copyWith(
          participation: MeetingParticipation.accepted,
          status: CalendarEventStatus.busy,
        ),
      MeetingInviteResponseType.tentative => event.copyWith(
          participation: MeetingParticipation.tentative,
          status: CalendarEventStatus.tentative,
        ),
      MeetingInviteResponseType.decline =>
        event.copyWith(participation: MeetingParticipation.declined),
    };

/// The event as it will look once [params] has been saved.
///
/// Fields the params do not carry are kept from [event] — the iCalendar UID,
/// whether we organise it, which series it belongs to, and each attendee's RSVP
/// (params hold addresses only, so a guest already listed keeps their response
/// instead of being reset to "no reply").
///
/// Two things this cannot know, both corrected by the next sync: the join URL
/// for a meeting only just made online, since only the provider can mint one,
/// and whatever normalisation the provider applies to a recurrence rule.
CalendarEvent applyUpdate(
  CalendarEvent event,
  UpdateCalendarEventParams params,
) {
  final existingByEmail = {
    for (final a in event.attendees) a.email.toLowerCase(): a,
  };
  return CalendarEvent(
    id: params.id,
    subject: params.subject,
    start: params.start,
    end: params.end,
    isAllDay: params.isAllDay,
    iCalUid: event.iCalUid,
    location: params.location,
    // Carried over, not taken from the params: an edit cannot change the join
    // link (no field offers it), and rebuilding without it would drop the Join
    // Meeting affordance from the cached copy until the next sync.
    onlineMeetingUrl: event.onlineMeetingUrl,
    bodyPreview: params.description,
    status: event.status,
    participation: event.participation,
    isOrganizer: event.isOrganizer,
    timezone: params.timezone,
    attendees: [
      for (final email in params.attendeeEmails)
        existingByEmail[email.toLowerCase()] ??
            CalendarEventAttendee(email: email),
      // Rooms are attendees too, just resource ones. Omitting them here would
      // make a just-booked room vanish from the reopened form until the next
      // sync — and reopening in that window would then save the meeting without
      // it, releasing the room the user just took.
      for (final email in params.roomEmails)
        existingByEmail[email.toLowerCase()] ??
            CalendarEventAttendee(email: email, isResource: true),
    ],
    recurrence: params.recurrence,
    reminderMinutes: params.reminderMinutes,
    seriesMasterId: event.seriesMasterId,
  );
}
