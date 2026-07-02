class ScheduledReminderRecord {
  const ScheduledReminderRecord({
    required this.accountId,
    required this.eventId,
    required this.triggerAtMs,
    required this.reminderMinutes,
    required this.eventStartMs,
  });

  final String accountId;
  final String eventId;
  final int triggerAtMs;
  final int reminderMinutes;
  final int eventStartMs;
}

abstract interface class ReminderScheduleLocalDatasource {
  Future<List<ScheduledReminderRecord>> getScheduledReminders(String accountId);

  Future<void> upsertScheduledReminder({
    required String accountId,
    required String eventId,
    required int triggerAtMs,
    required int reminderMinutes,
    required int eventStartMs,
  });

  Future<void> deleteScheduledReminder(String accountId, String eventId);

  Future<void> clearScheduledRemindersForAccount(String accountId);
}
