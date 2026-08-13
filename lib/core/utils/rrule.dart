import '../../domain/entities/calendar_recurrence.dart';

/// Serialises a [CalendarRecurrence] as an iCalendar `RRULE` content line.
///
/// Shared by the Google datasource (whose `recurrence` array wants exactly this
/// spelling) and the forwarded-invitation builder, so a series forwarded to
/// somebody repeats on the same days it does for everyone already in it.
/// `GoogleCalendarDatasourceImpl._parseRRule` is the inverse.
String buildRRule(CalendarRecurrence rawR) {
  final r = rawR.normalizedForSync();
  final freq = switch (r.frequency) {
    RecurrenceFrequency.daily => 'DAILY',
    RecurrenceFrequency.weekly => 'WEEKLY',
    RecurrenceFrequency.monthly => 'MONTHLY',
    RecurrenceFrequency.yearly => 'YEARLY',
  };
  var rule = 'FREQ=$freq';
  if (r.interval > 1) rule += ';INTERVAL=${r.interval}';

  if (r.frequency == RecurrenceFrequency.weekly &&
      r.daysOfWeek != null &&
      r.daysOfWeek!.isNotEmpty) {
    const dayNames = ['', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
    final days = r.daysOfWeek!.map((d) => dayNames[d]).join(',');
    rule += ';BYDAY=$days';
  }

  if (r.endDate != null) {
    rule += ';UNTIL=${_formatRRuleDate(r.endDate!)}';
  } else if (r.count != null) {
    rule += ';COUNT=${r.count}';
  }

  return 'RRULE:$rule';
}

String _formatRRuleDate(DateTime dt) {
  final utc = dt.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  return '$y$m${d}T000000Z';
}
