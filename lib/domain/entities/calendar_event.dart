import 'package:equatable/equatable.dart';

import 'calendar_event_attendee.dart';
import 'calendar_recurrence.dart';

enum CalendarEventStatus { free, busy, tentative, outOfOffice, workingElsewhere }

/// The current user's relationship to a meeting, derived from whether they
/// organised it and their RSVP. This drives the calendar tile colour and is
/// deliberately independent of the free/busy [CalendarEventStatus] (which is
/// used for conflict detection). Both the Google and O365 datasources map
/// their provider-specific fields into this shared enum so a meeting is
/// coloured the same way regardless of which account it came from.
enum MeetingParticipation {
  /// You own the meeting.
  organizer,

  /// You accepted someone else's invite.
  accepted,

  /// You tentatively accepted.
  tentative,

  /// You were invited but haven't responded yet.
  needsAction,

  /// You declined.
  declined,

  /// No participation signal available (e.g. an event on a subscribed
  /// calendar). Treated as "on your calendar" for colouring.
  none,
}

class CalendarEvent extends Equatable {
  const CalendarEvent({
    required this.id,
    required this.subject,
    required this.start,
    required this.end,
    required this.isAllDay,
    this.iCalUid,
    this.location,
    this.bodyPreview,
    this.status = CalendarEventStatus.busy,
    this.participation = MeetingParticipation.none,
    this.isOrganizer = false,
    this.timezone,
    this.attendees = const [],
    this.recurrence,
    this.reminderMinutes,
    this.seriesMasterId,
  });

  final String id;
  final String subject;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;

  /// The cross-provider iCalendar UID (Google `iCalUID`, Graph `iCalUId`),
  /// shared by every copy of a meeting on every attendee's calendar. Lets a
  /// meeting invite recognise the copy of *itself* that the provider already
  /// added to the calendar, instead of reporting it as a clash. Null for
  /// providers that don't expose it.
  final String? iCalUid;

  final String? location;
  final String? bodyPreview;
  final CalendarEventStatus status;

  /// The current user's relationship to this meeting (organiser / accepted /
  /// tentative / …), used to colour the calendar tile. See [MeetingParticipation].
  final MeetingParticipation participation;

  final bool isOrganizer;

  /// IANA timezone string (e.g. "America/New_York"). Null means UTC.
  final String? timezone;

  final List<CalendarEventAttendee> attendees;
  final CalendarRecurrence? recurrence;

  /// Minutes before the event start to fire a reminder. Null means no reminder.
  final int? reminderMinutes;

  /// Non-null when this event is an occurrence within a recurring series.
  /// Holds the ID of the series master event (Graph: seriesMasterId, Google: recurringEventId).
  final String? seriesMasterId;

  bool get isRecurringOccurrence => seriesMasterId != null;

  Duration get duration => end.difference(start);

  /// Whether this event actually occupies its slot, for conflict detection.
  /// [CalendarEventStatus.free] is explicit availability; `workingElsewhere` is
  /// a location marker (a Google working-location entry, Graph's
  /// "working elsewhere") rather than a commitment, so neither clashes with a
  /// new invite. Everything else — including a tentative or unanswered
  /// meeting — does.
  bool get blocksTime =>
      status != CalendarEventStatus.free &&
      status != CalendarEventStatus.workingElsewhere;

  @override
  List<Object?> get props => [id];
}
