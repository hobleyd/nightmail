import 'dart:io';

typedef TzEntry = ({String iana, String label, String abbreviation, int offsetHours});

final List<TzEntry> kTimezones = List.unmodifiable(
  <TzEntry>[
  (iana: 'UTC', label: 'UTC', abbreviation: 'UTC', offsetHours: 0),
  (iana: 'America/New_York', label: 'Eastern (ET)', abbreviation: 'EST', offsetHours: -5),
  (iana: 'America/Chicago', label: 'Central (CT)', abbreviation: 'CST', offsetHours: -6),
  (iana: 'America/Denver', label: 'Mountain (MT)', abbreviation: 'MST', offsetHours: -7),
  (iana: 'America/Los_Angeles', label: 'Pacific (PT)', abbreviation: 'PST', offsetHours: -8),
  (iana: 'America/Anchorage', label: 'Alaska (AKT)', abbreviation: 'AKST', offsetHours: -9),
  (iana: 'Pacific/Honolulu', label: 'Hawaii (HT)', abbreviation: 'HST', offsetHours: -10),
  (iana: 'America/Toronto', label: 'Toronto', abbreviation: 'EST', offsetHours: -5),
  (iana: 'America/Vancouver', label: 'Vancouver', abbreviation: 'PST', offsetHours: -8),
  (iana: 'America/Sao_Paulo', label: 'São Paulo (BRT)', abbreviation: 'BRT', offsetHours: -3),
  (iana: 'America/Mexico_City', label: 'Mexico City', abbreviation: 'CST', offsetHours: -6),
  (iana: 'America/Buenos_Aires', label: 'Buenos Aires', abbreviation: 'ART', offsetHours: -3),
  (iana: 'Europe/London', label: 'London (GMT/BST)', abbreviation: 'GMT', offsetHours: 0),
  (iana: 'Europe/Paris', label: 'Paris (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Berlin', label: 'Berlin (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Rome', label: 'Rome (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Madrid', label: 'Madrid (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Amsterdam', label: 'Amsterdam (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Warsaw', label: 'Warsaw (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Stockholm', label: 'Stockholm (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Helsinki', label: 'Helsinki (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Europe/Athens', label: 'Athens (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Europe/Istanbul', label: 'Istanbul (TRT)', abbreviation: 'TRT', offsetHours: 3),
  (iana: 'Europe/Moscow', label: 'Moscow (MSK)', abbreviation: 'MSK', offsetHours: 3),
  (iana: 'Asia/Dubai', label: 'Dubai (GST)', abbreviation: 'GST', offsetHours: 4),
  (iana: 'Asia/Kolkata', label: 'India (IST)', abbreviation: 'IST', offsetHours: 5),
  (iana: 'Asia/Dhaka', label: 'Dhaka (BST)', abbreviation: 'BST', offsetHours: 6),
  (iana: 'Asia/Bangkok', label: 'Bangkok (ICT)', abbreviation: 'ICT', offsetHours: 7),
  (iana: 'Asia/Shanghai', label: 'Beijing/Shanghai (CST)', abbreviation: 'CST', offsetHours: 8),
  (iana: 'Asia/Hong_Kong', label: 'Hong Kong (HKT)', abbreviation: 'HKT', offsetHours: 8),
  (iana: 'Asia/Singapore', label: 'Singapore (SGT)', abbreviation: 'SGT', offsetHours: 8),
  (iana: 'Asia/Taipei', label: 'Taipei (CST)', abbreviation: 'CST', offsetHours: 8),
  (iana: 'Asia/Seoul', label: 'Seoul (KST)', abbreviation: 'KST', offsetHours: 9),
  (iana: 'Asia/Tokyo', label: 'Tokyo (JST)', abbreviation: 'JST', offsetHours: 9),
  (iana: 'Australia/Perth', label: 'Perth (AWST)', abbreviation: 'AWST', offsetHours: 8),
  (iana: 'Australia/Adelaide', label: 'Adelaide (ACST)', abbreviation: 'ACST', offsetHours: 9),
  (iana: 'Australia/Brisbane', label: 'Brisbane (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Australia/Sydney', label: 'Sydney (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Australia/Melbourne', label: 'Melbourne (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Pacific/Auckland', label: 'Auckland (NZST)', abbreviation: 'NZST', offsetHours: 12),
  (iana: 'Africa/Johannesburg', label: 'Johannesburg (SAST)', abbreviation: 'SAST', offsetHours: 2),
  (iana: 'Africa/Cairo', label: 'Cairo (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Africa/Lagos', label: 'Lagos (WAT)', abbreviation: 'WAT', offsetHours: 1),
  ]..sort((a, b) => a.offsetHours.compareTo(b.offsetHours)),
);

/// Returns the IANA timezone for the device's current locale.
///
/// Resolution order:
///  1. Read the /etc/localtime symlink (macOS/Linux — gives exact IANA name).
///  2. Match timezone abbreviation against the known list.
///  3. Match UTC offset against the known list.
///  4. Fall back to UTC.
String localIanaTimezone() {
  try {
    final target = Link('/etc/localtime').targetSync();
    for (final prefix in [
      '/var/db/timezone/zoneinfo/', // macOS
      '/usr/share/zoneinfo/', // Linux
      'zoneinfo/',
    ]) {
      final idx = target.indexOf(prefix);
      if (idx >= 0) {
        final iana = target.substring(idx + prefix.length);
        if (iana.isNotEmpty) return iana;
      }
    }
  } catch (_) {}

  final offset = DateTime.now().timeZoneOffset;
  final name = DateTime.now().timeZoneName;
  for (final tz in kTimezones) {
    if (tz.abbreviation == name) return tz.iana;
  }
  for (final tz in kTimezones) {
    if (tz.offsetHours == offset.inHours) return tz.iana;
  }
  return 'UTC';
}
