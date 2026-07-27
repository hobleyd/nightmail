/// Hour of the day that follow-up due dates land on — "morning".
const followUpMorningHour = 9;

/// Returns the [count]th business day (Mon–Fri) after [from], at [atHour].
///
/// Weekend days are skipped, so Friday + 1 is Monday and Saturday + 1 is
/// Monday. A [count] of 0 or less returns [from]'s own day at [atHour].
///
/// The result is rebuilt a day at a time rather than by adding a [Duration]
/// so the wall-clock hour survives a daylight-saving transition.
DateTime addBusinessDays(
  DateTime from,
  int count, {
  int atHour = followUpMorningHour,
}) {
  var day = DateTime(from.year, from.month, from.day, atHour);
  var remaining = count;
  while (remaining > 0) {
    day = DateTime(day.year, day.month, day.day + 1, atHour);
    if (day.weekday != DateTime.saturday && day.weekday != DateTime.sunday) {
      remaining--;
    }
  }
  return day;
}
