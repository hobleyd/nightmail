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
