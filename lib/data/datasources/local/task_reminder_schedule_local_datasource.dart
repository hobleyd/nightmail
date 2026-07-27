class ScheduledTaskReminderRecord {
  const ScheduledTaskReminderRecord({
    required this.accountId,
    required this.listId,
    required this.taskId,
    required this.triggerAtMs,
    required this.dueAtMs,
    required this.osScheduled,
    this.notifiedAtMs,
  });

  final String accountId;
  final String listId;
  final String taskId;
  final int triggerAtMs;
  final int dueAtMs;

  /// True when the trigger was handed to an OS scheduler that survives the
  /// app exiting (UNUserNotificationCenter / WinRT toast / AlarmManager),
  /// false when it is only held by an in-process timer (Linux).
  final bool osScheduled;

  /// Set once a notification has actually been shown for [triggerAtMs] — the
  /// guard against re-notifying the same due date on every reconcile pass.
  final int? notifiedAtMs;
}

abstract interface class TaskReminderScheduleLocalDatasource {
  Future<List<ScheduledTaskReminderRecord>> getScheduledTaskReminders(
      String accountId);

  Future<void> upsertScheduledTaskReminder({
    required String accountId,
    required String listId,
    required String taskId,
    required int triggerAtMs,
    required int dueAtMs,
    required bool osScheduled,
    int? notifiedAtMs,
  });

  Future<void> markTaskReminderNotified({
    required String accountId,
    required String taskId,
    required int notifiedAtMs,
  });

  Future<void> deleteScheduledTaskReminder(String accountId, String taskId);

  Future<void> clearScheduledTaskRemindersForAccount(String accountId);
}
