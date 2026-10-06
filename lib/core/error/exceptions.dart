class ServerException implements Exception {
  const ServerException({required this.message, this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ServerException($statusCode): $message';
}

class AuthException implements Exception {
  const AuthException({required this.message});
  final String message;

  @override
  String toString() => 'AuthException: $message';
}

class CacheException implements Exception {
  const CacheException({required this.message});
  final String message;

  @override
  String toString() => 'CacheException: $message';
}

class NetworkException implements Exception {
  const NetworkException({required this.message});
  final String message;

  @override
  String toString() => 'NetworkException: $message';
}

/// The provider will not forward a meeting on the organizer's behalf.
///
/// Either the account type has no meeting-forward API at all (IMAP, CalDAV,
/// EventKit) or the organizer's own policy forbids it — Exchange's "allow
/// forwarding" switch, Google's `guestsCanInviteOthers`. That is a *settled*
/// answer rather than a transient failure, which is why it is its own type:
/// `CalendarRepositoryImpl` reads it as "fall back to emailing the invitation
/// from this account" instead of reporting a failure to the user.
class MeetingForwardUnsupportedException implements Exception {
  const MeetingForwardUnsupportedException({required this.message});
  final String message;

  @override
  String toString() => 'MeetingForwardUnsupportedException: $message';
}

/// The provider holds no copy of the meeting an invitation is for, so there is
/// nothing on the calendar for an RSVP to be applied to.
///
/// A settled answer, not a transient one: the lookups by `UID` and by start
/// time have both come up empty. It is what a *forwarded* invitation looks
/// like — somebody passed the organizer's invitation on by email, this account
/// is not on its guest list, and so the provider never filed the meeting.
/// `CalendarRepositoryImpl.respondToMeetingInvite` answers that case by
/// keeping a private copy and emailing the organizer; any other not-found is
/// reported as the failure it is.
///
/// Still a [ServerException] with a 404, because that is the calendar outbox's
/// drop signal: a queued RSVP that lands here can never start succeeding.
class MeetingNotOnCalendarException extends ServerException {
  const MeetingNotOnCalendarException({required super.message})
      : super(statusCode: 404);

  @override
  String toString() => 'MeetingNotOnCalendarException: $message';
}

/// The cloud document a body link points at is not something the reading pane
/// can show — an archive, a video, an unknown binary.
///
/// Thrown by the drive datasources *before* they download anything, so a file
/// that could only have ended in an apology is never fetched. The repository
/// reads it as "leave this link to the browser", which is where it would have
/// opened before any of this existed.
class CloudDocumentNotPreviewableException implements Exception {
  const CloudDocumentNotPreviewableException({required this.message});
  final String message;

  @override
  String toString() => 'CloudDocumentNotPreviewableException: $message';
}
