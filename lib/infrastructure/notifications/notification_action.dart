sealed class NotificationAction {}

final class OpenEmailAction extends NotificationAction {
  OpenEmailAction({required this.emailId, required this.accountId});
  final String emailId;
  final String accountId;
}

final class OpenCalendarEventAction extends NotificationAction {
  OpenCalendarEventAction({required this.eventId, this.startIso});
  final String eventId;
  final String? startIso;
}
