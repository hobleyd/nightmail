import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'windows_timezones.dart';

class IcsEvent {
  const IcsEvent({
    required this.summary,
    required this.start,
    required this.end,
    required this.isAllDay,
    this.uid,
    this.location,
    this.attendees = const [],
  });

  final String summary;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? uid;
  final String? location;
  final List<String> attendees;
}

class IcsParser {
  /// Parses the first VEVENT from an iCalendar string.
  static IcsEvent parse(String icsData) {
    // Unfold continuation lines (RFC 5545: CRLF followed by whitespace).
    final unfolded = icsData.replaceAll(RegExp(r'\r?\n[ \t]'), '');

    String? summary;
    String? uid;
    DateTime? start;
    DateTime? end;
    Duration? duration;
    bool isAllDay = false;
    String? location;
    final attendees = <String>[];

    bool inVEvent = false;
    for (final rawLine in unfolded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase() == 'BEGIN:VEVENT') {
        inVEvent = true;
        continue;
      }
      if (line.toUpperCase() == 'END:VEVENT') break;
      if (!inVEvent) continue;

      final colonIdx = line.indexOf(':');
      if (colonIdx == -1) continue;

      // Keep the original case for TZID extraction (IANA names are
      // case-sensitive, e.g. America/New_York); match property names
      // case-insensitively below.
      final rawName = line.substring(0, colonIdx);
      final namePart = rawName.toUpperCase();
      final value = line.substring(colonIdx + 1);

      if (namePart == 'SUMMARY') {
        summary = value;
      } else if (namePart == 'UID') {
        uid = value;
      } else if (namePart.startsWith('DTSTART')) {
        final (dt, allDay) = parseDateTime(rawName, value);
        if (dt != null) {
          start = dt;
          isAllDay = allDay;
        }
      } else if (namePart.startsWith('DTEND')) {
        final (dt, _) = parseDateTime(rawName, value);
        if (dt != null) end = dt;
      } else if (namePart == 'DURATION') {
        duration = parseDuration(value);
      } else if (namePart == 'LOCATION') {
        location = value.isNotEmpty ? value : null;
      } else if (namePart.startsWith('ATTENDEE')) {
        final mailto = value.toLowerCase().startsWith('mailto:')
            ? value.substring('mailto:'.length)
            : value;
        if (mailto.contains('@')) attendees.add(mailto);
      }
    }

    return IcsEvent(
      summary: summary ?? '(No title)',
      uid: uid,
      start: start ?? DateTime.now().toUtc(),
      end: end ??
          (start != null && duration != null
              ? start.add(duration)
              : (start ?? DateTime.now().toUtc())
                  .add(const Duration(hours: 1))),
      isAllDay: isAllDay,
      location: location,
      attendees: attendees,
    );
  }

  /// Parses a DTSTART/DTEND property.
  ///
  /// [namePart] is the property name *with parameters* and in its original
  /// case (e.g. `DTSTART;TZID=America/New_York`) so the case-sensitive IANA
  /// TZID can be recovered.
  static (DateTime?, bool) parseDateTime(String namePart, String value) {
    final upperName = namePart.toUpperCase();
    // All-day: VALUE=DATE (not DATE-TIME).
    final isDate =
        upperName.contains('VALUE=DATE') && !upperName.contains('DATE-TIME');
    if (isDate) {
      if (value.length >= 8) {
        final y = int.tryParse(value.substring(0, 4));
        final m = int.tryParse(value.substring(4, 6));
        final d = int.tryParse(value.substring(6, 8));
        if (y != null && m != null && d != null) {
          return (DateTime.utc(y, m, d), true);
        }
      }
      return (null, true);
    }

    // Three forms:
    //   UTC:            20260615T100000Z
    //   zoned (TZID):   DTSTART;TZID=America/New_York:20260615T100000
    //   floating:       20260615T100000   (no Z, no TZID)
    final isUtc = value.endsWith('Z');
    final digits = value.replaceAll(RegExp(r'[TZ]'), '');
    if (digits.length >= 14) {
      final y = int.tryParse(digits.substring(0, 4));
      final mo = int.tryParse(digits.substring(4, 6));
      final d = int.tryParse(digits.substring(6, 8));
      final h = int.tryParse(digits.substring(8, 10));
      final mi = int.tryParse(digits.substring(10, 12));
      final s = int.tryParse(digits.substring(12, 14));
      if (y != null &&
          mo != null &&
          d != null &&
          h != null &&
          mi != null &&
          s != null) {
        final DateTime dt;
        if (isUtc) {
          dt = DateTime.utc(y, mo, d, h, mi, s);
        } else {
          final tzid = _extractTzid(namePart);
          dt = _fromTzid(tzid, y, mo, d, h, mi, s) ??
              // No TZID (or an unresolvable one): interpret the wall-clock
              // time in the host's local zone as a last resort.
              DateTime(y, mo, d, h, mi, s).toUtc();
        }
        return (dt, false);
      }
    }
    return (null, false);
  }

  /// Extracts the IANA TZID from a property name+parameters string, e.g.
  /// `DTSTART;TZID=America/New_York` → `America/New_York`. Handles optional
  /// surrounding quotes. Returns null if no TZID parameter is present.
  static String? _extractTzid(String namePart) {
    final match =
        RegExp(r'TZID=([^;:]+)', caseSensitive: false).firstMatch(namePart);
    if (match == null) return null;
    final tzid = match.group(1)!.replaceAll('"', '').trim();
    return tzid.isEmpty ? null : tzid;
  }

  static bool _tzInitialized = false;

  /// Interprets a wall-clock time as being in the zone [tzid] and returns the
  /// equivalent UTC instant. Accepts IANA names (e.g. "America/New_York") and
  /// Windows/Outlook names (e.g. "AUS Eastern Standard Time"), the latter via
  /// [windowsZoneToIana]. Returns null when [tzid] is null or unresolvable, so
  /// the caller can fall back.
  static DateTime? _fromTzid(
      String? tzid, int y, int mo, int d, int h, int mi, int s) {
    if (tzid == null) return null;
    try {
      if (!_tzInitialized) {
        tz_data.initializeTimeZones();
        _tzInitialized = true;
      }
      tz.Location location;
      try {
        location = tz.getLocation(tzid);
      } catch (_) {
        // Not an IANA name — try mapping a Windows zone name.
        final iana = windowsZoneToIana(tzid);
        if (iana == null) return null;
        location = tz.getLocation(iana);
      }
      final zoned = tz.TZDateTime(location, y, mo, d, h, mi, s);
      // Return a *plain* UTC DateTime, not the TZDateTime itself:
      // TZDateTime.toLocal() converts to the timezone package's tz.local
      // (which defaults to UTC unless setLocalLocation was called), whereas
      // the display code expects DateTime.toLocal() to honor the OS zone.
      return DateTime.fromMillisecondsSinceEpoch(
        zoned.millisecondsSinceEpoch,
        isUtc: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses an RFC 5545 DURATION value, e.g. "PT1H30M", "P1DT2H", "-P1D".
  static Duration? parseDuration(String value) {
    final match = RegExp(
      r'^([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;

    final weeks = int.tryParse(match.group(2) ?? '') ?? 0;
    final days = int.tryParse(match.group(3) ?? '') ?? 0;
    final hours = int.tryParse(match.group(4) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(5) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(6) ?? '') ?? 0;
    final total = Duration(
      days: weeks * 7 + days,
      hours: hours,
      minutes: minutes,
      seconds: seconds,
    );
    return match.group(1) == '-' ? -total : total;
  }
}
