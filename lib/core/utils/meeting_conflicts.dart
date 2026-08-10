import '../../domain/entities/calendar_event.dart';

/// Picks the calendar events that genuinely clash with an incoming meeting
/// invite, for the warning shown in the invite banner.
///
/// Three rules, all of which have silently swallowed real conflicts before:
///
///  * **Overlap is half-open.** Back-to-back meetings (one ending exactly when
///    the next starts) are not a clash.
///  * **Only time-blocking events count** — see [CalendarEvent.blocksTime].
///    An event the user marked free, declined, or a working-location entry
///    does not clash; a tentative or still-unanswered meeting does.
///  * **The invite's own copy is not a clash.** Gmail and Exchange both add a
///    meeting to the calendar as soon as the invite arrives, so that copy comes
///    back from the calendar query. It is identified by [inviteUid] matching
///    [CalendarEvent.iCalUid]. Only when neither side exposes a UID do we fall
///    back to excluding an event that occupies exactly the invited slot — a
///    heuristic that on its own also hides a genuine double-booking over the
///    same slot, which is the most likely kind of double-booking there is.
///
/// [meetingStart]/[meetingEnd] and the event times are compared as instants, so
/// the caller does not need to normalise time zones.
List<CalendarEvent> findMeetingConflicts({
  required Iterable<CalendarEvent> events,
  required DateTime meetingStart,
  required DateTime meetingEnd,
  String? inviteUid,
}) {
  final inviteKey = _uidKey(inviteUid);

  return events.where((e) {
    if (!e.blocksTime) return false;

    final eventKey = _uidKey(e.iCalUid);
    if (inviteKey != null && eventKey != null) {
      if (eventKey == inviteKey) return false; // this invite's own copy
    } else if (e.start.isAtSameMomentAs(meetingStart) &&
        e.end.isAtSameMomentAs(meetingEnd)) {
      return false; // no UID to match on — assume the auto-added copy
    }

    return e.start.isBefore(meetingEnd) && e.end.isAfter(meetingStart);
  }).toList();
}

/// Whether two iCalendar UIDs name the same meeting, allowing for the mangling
/// described on [_uidKey]. False when either side has no UID: an unknown UID
/// matches nothing, rather than everything.
///
/// Used to tell whether an event is *already* on the calendar — the question
/// [findMeetingConflicts] answers in passing for an invite the provider
/// auto-added, and the one a published event has to ask outright, since nothing
/// adds it but the user pressing the button.
bool isSameMeetingUid(String? a, String? b) {
  final keyA = _uidKey(a);
  final keyB = _uidKey(b);
  return keyA != null && keyA == keyB;
}

/// Reduces an iCalendar UID to a form comparable across providers.
///
/// Google gives each expanded instance of a recurring series an `iCalUID` of
/// `<masterUid>_<instanceStart>@google.com`, while the ICS attached to the
/// invite carries the bare master UID — so the instance suffix and the domain
/// are both dropped before comparing.
String? _uidKey(String? uid) {
  if (uid == null) return null;
  var key = uid.trim().toLowerCase();
  final at = key.indexOf('@');
  if (at > 0) key = key.substring(0, at);
  final underscore = key.indexOf('_');
  if (underscore > 0) key = key.substring(0, underscore);
  return key.isEmpty ? null : key;
}
