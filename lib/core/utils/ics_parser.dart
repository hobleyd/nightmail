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

      final namePart = line.substring(0, colonIdx).toUpperCase();
      final value = line.substring(colonIdx + 1);

      if (namePart == 'SUMMARY') {
        summary = value;
      } else if (namePart == 'UID') {
        uid = value;
      } else if (namePart.startsWith('DTSTART')) {
        final (dt, allDay) = parseDateTime(namePart, value);
        if (dt != null) {
          start = dt;
          isAllDay = allDay;
        }
      } else if (namePart.startsWith('DTEND')) {
        final (dt, _) = parseDateTime(namePart, value);
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

  static (DateTime?, bool) parseDateTime(String namePart, String value) {
    // All-day: VALUE=DATE (not DATE-TIME).
    final isDate =
        namePart.contains('VALUE=DATE') && !namePart.contains('DATE-TIME');
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

    // UTC: 20260615T100000Z  or  local with TZID: 20260615T100000
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
        final dt = isUtc
            ? DateTime.utc(y, mo, d, h, mi, s)
            : DateTime(y, mo, d, h, mi, s).toUtc();
        return (dt, false);
      }
    }
    return (null, false);
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
