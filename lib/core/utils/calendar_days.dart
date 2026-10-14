/// Calendar-day arithmetic that survives a daylight-saving change.
///
/// `d.add(Duration(days: 1))` adds 24 hours, not a day: across the October
/// change in Sydney a midnight becomes 1:00, and across the April change it
/// becomes 23:00 *on the same day*, so a loop stepping days repeats one.
/// Building the date from its fields lets `DateTime` normalise instead.
library;

/// Midnight [days] calendar days after [d]'s day (negative goes back).
DateTime addCalendarDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);
