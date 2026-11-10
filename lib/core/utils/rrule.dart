import '../../domain/entities/calendar_recurrence.dart';

/// Serialises a [CalendarRecurrence] as an iCalendar `RRULE` content line.
///
/// Shared by the Google datasource (whose `recurrence` array wants exactly this
/// spelling) and the forwarded-invitation builder, so a series forwarded to
/// somebody repeats on the same days it does for everyone already in it.
/// [parseRRule] is the inverse.
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

/// Picks the RRULE line out of a `recurrence` array (which may also contain
/// EXDATE/RDATE/EXRULE lines) and parses it. Google's event `recurrence` field
/// is one; the RRULE of an invitation's `VEVENT` is another.
CalendarRecurrence? parseRecurrenceRules(Iterable<String>? rules) {
  if (rules == null) return null;
  for (final raw in rules) {
    final line = raw.trim();
    if (line.toUpperCase().startsWith('RRULE')) return parseRRule(line);
  }
  return null;
}

/// Inverse of [buildRRule]: parses an iCalendar RRULE line into a
/// [CalendarRecurrence]. Returns null if FREQ is missing or unrecognized.
CalendarRecurrence? parseRRule(String line) {
  // Drop an optional "RRULE:" prefix, then split the ";"-separated params.
  final body =
      line.contains(':') ? line.substring(line.indexOf(':') + 1) : line;
  final params = <String, String>{};
  for (final part in body.split(';')) {
    final eq = part.indexOf('=');
    if (eq > 0) {
      params[part.substring(0, eq).toUpperCase()] = part.substring(eq + 1);
    }
  }

  final frequency = switch (params['FREQ']?.toUpperCase()) {
    'DAILY' => RecurrenceFrequency.daily,
    'WEEKLY' => RecurrenceFrequency.weekly,
    'MONTHLY' => RecurrenceFrequency.monthly,
    'YEARLY' => RecurrenceFrequency.yearly,
    _ => null,
  };
  if (frequency == null) return null;

  final interval = int.tryParse(params['INTERVAL'] ?? '') ?? 1;

  List<int>? daysOfWeek;
  final byDay = params['BYDAY'];
  if (byDay != null && byDay.isNotEmpty) {
    const dayNumbers = {
      'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7,
    };
    final days = byDay
        .split(',')
        .map((token) {
          // BYDAY entries may carry an ordinal prefix, e.g. "2MO" or "-1FR";
          // the day code is always the trailing two letters.
          final code = token.trim().toUpperCase();
          final key = code.length >= 2 ? code.substring(code.length - 2) : code;
          return dayNumbers[key];
        })
        .whereType<int>()
        .toList();
    if (days.isNotEmpty) daysOfWeek = days;
  }

  DateTime? endDate;
  int? count;
  final until = params['UNTIL'];
  final countStr = params['COUNT'];
  if (until != null && until.isNotEmpty) {
    endDate = _parseUntil(until);
  } else if (countStr != null) {
    count = int.tryParse(countStr);
  }

  return CalendarRecurrence(
    frequency: frequency,
    interval: interval,
    daysOfWeek: daysOfWeek,
    endDate: endDate,
    count: count,
  );
}

/// Parses an RRULE UNTIL value (`yyyymmdd`, `yyyymmddThhmmss`, or
/// `yyyymmddThhmmssZ`) into a local date. Only the calendar date is kept, to
/// match how the recurrence end date is represented elsewhere (Graph returns
/// a plain date), and to avoid a timezone shift moving it to an adjacent day.
DateTime? _parseUntil(String raw) {
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(raw.trim());
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
}
