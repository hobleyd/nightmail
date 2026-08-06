/// Telling a meeting's join link apart from the place it is held.
///
/// `CalendarEvent` keeps the two in separate fields — `location` is where you
/// go, `onlineMeetingUrl` is what you click. They used to be one field, which
/// meant a provider's join URL overwrote whatever the user had typed and
/// composing anything in front of it (a room name, say) silently broke the Join
/// Meeting affordance.
///
/// Events written under the old convention still have their join URL sitting in
/// `location`, on the server and in the local cache, so reading one has to be
/// able to pull them back apart — that is [splitMeetingLocation].
library;

final _joinUrlPattern = RegExp(
  r'^https://(?:'
  r'teams\.microsoft\.com/l/meetup-join'
  r'|teams\.live\.com/meet'
  r'|meet\.google\.com'
  r'|.*\.zoom\.us/j/'
  r'|zoom\.us/j/'
  r')',
  caseSensitive: false,
);

/// Whether [location] is a join link rather than a place.
bool isOnlineMeetingUrl(String? location) {
  final s = location?.trim();
  if (s == null || s.isEmpty) return false;
  return _joinUrlPattern.hasMatch(s);
}

/// Names the platform a join link belongs to, for showing instead of the URL —
/// which is a long opaque token that tells a reader nothing.
String onlineMeetingPlatformName(String url) {
  final u = url.toLowerCase();
  if (u.contains('teams.microsoft.com') || u.contains('teams.live.com')) {
    return 'Microsoft Teams';
  }
  if (u.contains('meet.google.com')) return 'Google Meet';
  if (u.contains('zoom.us')) return 'Zoom';
  return 'Online meeting';
}

/// A join link anywhere inside free text — how a meeting invitation that only
/// pastes the link into its body is still made joinable.
final _embeddedJoinUrl = RegExp(
  r'https://(?:teams\.microsoft\.com/l/meetup-join|teams\.live\.com/meet'
  r'|meet\.google\.com|[\w.-]*\.?zoom\.us/j/)[^\s<>"\)\]]*',
  caseSensitive: false,
);

/// Splits what a provider gives us into the place and the join link.
///
/// [onlineMeetingUrl] is the provider's own field (Graph `onlineMeeting.joinUrl`,
/// Google's `conferenceData` video entry point) and wins outright. Failing that,
/// a [rawLocation] that is itself a join URL is treated as one — that is the
/// shape every event saved under the old single-field convention is in, so
/// without this those meetings would quietly stop being joinable. [description]
/// is scraped only as a last resort, for invitations that put the link in the
/// body and nowhere else.
///
/// A [rawLocation] that is a join URL is *not* also returned as the location: it
/// was never a place, and echoing it back would put it straight back into the
/// field the user types their location into.
({String? location, String? onlineMeetingUrl}) splitMeetingLocation({
  String? rawLocation,
  String? onlineMeetingUrl,
  String? description,
}) {
  final place = rawLocation?.trim();
  final locationIsLink = isOnlineMeetingUrl(place);

  var url = onlineMeetingUrl?.trim();
  if (url == null || url.isEmpty) {
    if (locationIsLink) {
      url = place;
    } else if (description != null) {
      url = _embeddedJoinUrl.firstMatch(description)?.group(0);
    }
  }

  return (
    location: (place == null || place.isEmpty || locationIsLink) ? null : place,
    onlineMeetingUrl: (url == null || url.isEmpty) ? null : url,
  );
}
