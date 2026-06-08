import 'package:intl/intl.dart';

String formatEmailDate(DateTime date) {
  final localDate = date.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final emailDay = DateTime(localDate.year, localDate.month, localDate.day);

  if (emailDay == today) {
    return DateFormat('h:mm a').format(localDate);
  }
  if (emailDay.isAfter(today.subtract(const Duration(days: 6)))) {
    return DateFormat('EEE').format(localDate);
  }
  if (localDate.year == now.year) {
    return DateFormat('MMM d').format(localDate);
  }
  return DateFormat('MMM d, y').format(localDate);
}

String formatEmailDateLong(DateTime date) {
  final localDate = date.toLocal();
  return '${DateFormat('EEE, MMM d, y \'at\' h:mm a').format(localDate)} (${localDate.timeZoneName})';
}
