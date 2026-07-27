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

final class OpenTaskAction extends NotificationAction {
  OpenTaskAction({
    required this.taskId,
    required this.listId,
    required this.accountId,
  });
  final String taskId;
  final String listId;
  final String accountId;
}

/// Raised by the aggregate "N tasks are due" alert, which names an account but
/// no single task to open.
final class OpenTasksAction extends NotificationAction {
  OpenTasksAction({required this.accountId});
  final String accountId;
}
