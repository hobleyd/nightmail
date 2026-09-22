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

  /// Every account id that has at least one row, configured or not — the
  /// reconciler compares this against the accounts it actually has to find
  /// rows nothing will ever revisit.
  Future<Set<String>> getScheduledReminderAccountIds();
}
