/// When a to-do item counts as overdue — one rule, shared by the tasks pane's
/// red due line and the folder panel's Tasks badge, so the two can never
/// disagree about the same task.
library;

/// The calendar day a due moment refers to.
///
/// Microsoft To Do and Google Tasks both store "due" as a *date*, which arrives
/// as midnight UTC. So the day has to be read off the UTC side: in a UTC-behind
/// timezone the local side has already slipped to the previous day, which would
/// make every dated task look a day early. Same reasoning as
/// `TaskReminderService.triggerFor`. A due moment carrying a real time of day
/// is a local moment and is read as one.
DateTime taskDueDay(DateTime due) {
  final utc = due.toUtc();
  final isDateOnly = utc.hour == 0 &&
      utc.minute == 0 &&
      utc.second == 0 &&
      utc.millisecond == 0;
  return isDateOnly
      ? DateTime(utc.year, utc.month, utc.day)
      : DateTime(due.year, due.month, due.day);
}

/// Whether [due] has already passed. A task due *today* is not overdue — it
/// still has the day to run.
bool isTaskOverdue(DateTime due, {DateTime? now}) {
  final n = now ?? DateTime.now();
  return taskDueDay(due).isBefore(DateTime(n.year, n.month, n.day));
}
