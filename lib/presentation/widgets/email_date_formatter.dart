import 'package:intl/intl.dart';

String formatEmailDate(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final emailDay = DateTime(date.year, date.month, date.day);

  if (emailDay == today) {
    return DateFormat('h:mm a').format(date);
  }
  if (emailDay.isAfter(today.subtract(const Duration(days: 6)))) {
    return DateFormat('EEE').format(date);
  }
  if (date.year == now.year) {
    return DateFormat('MMM d').format(date);
  }
  return DateFormat('MMM d, y').format(date);
}

String formatEmailDateLong(DateTime date) {
  return DateFormat('EEE, MMM d, y \'at\' h:mm a').format(date);
}
