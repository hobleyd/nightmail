import 'dart:convert';

/// The RFC 5545 writing primitives every iCalendar this app emits is built
/// from — escaping, folding, date formatting, and copying properties through
/// from an original unchanged.
///
/// Split out of `ics_counter_builder.dart` when a second builder
/// ([buildForwardRequestIcs]) needed the same rules. Getting any of these
/// subtly wrong produces a file that parses in one client and not in another,
/// so there is exactly one implementation of each.

/// Escapes a TEXT value per RFC 5545 §3.3.11.
String icsEscape(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll(';', '\\;')
    .replaceAll(',', '\\,')
    .replaceAll('\r\n', '\\n')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\n');

/// `;CN="Name"` when a display name is known, else the empty string.
String icsCnParam(String? name) {
  if (name == null || name.trim().isEmpty) return '';
  // Quoted-string parameter values cannot themselves contain a double quote.
  return ';CN="${name.trim().replaceAll('"', "'")}"';
}

/// A UTC date-time value: `20260615T100000Z`.
String icsFormatUtc(DateTime dt) {
  final utc = dt.toUtc();
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${p(utc.year, 4)}${p(utc.month)}${p(utc.day)}'
      'T${p(utc.hour)}${p(utc.minute)}${p(utc.second)}Z';
}

/// A `VALUE=DATE` value: `20260615`. Used for all-day events, whose bounds are
/// dates rather than instants — writing one as a UTC date-time shifts the day
/// for every reader east or west of Greenwich.
String icsFormatDate(DateTime dt) {
  final utc = dt.toUtc();
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${p(utc.year, 4)}${p(utc.month)}${p(utc.day)}';
}

/// Folds a content line to 75 octets, continuing with a leading space.
///
/// Measures UTF-8 octets, not characters, and never splits a multi-byte
/// character across the fold — a receiver rejoins the octets before decoding,
/// so a split would corrupt the character.
String icsFold(String line) {
  const limit = 75;
  if (utf8.encode(line).length <= limit) return line;

  final out = StringBuffer();
  var lineBytes = 0;
  for (final rune in line.runes) {
    final charBytes = _utf8Length(rune);
    if (lineBytes + charBytes > limit) {
      out.write('\r\n ');
      // The leading space of a folded line counts toward its own 75 octets.
      lineBytes = 1;
    }
    out.write(String.fromCharCode(rune));
    lineBytes += charBytes;
  }
  return out.toString();
}

int _utf8Length(int rune) {
  if (rune < 0x80) return 1;
  if (rune < 0x800) return 2;
  if (rune < 0x10000) return 3;
  return 4;
}

/// Folds every line and joins them into a finished iCalendar document.
/// RFC 5545 requires CRLF endings, including after the last line.
String icsDocument(List<String> lines) =>
    '${lines.map(icsFold).join('\r\n')}\r\n';

/// The lines of [originalIcs] whose property name is one of [propertyNames],
/// unfolded and copied through **verbatim** — parameters and all.
///
/// Used for the properties a derived calendar object must echo rather than
/// re-derive. `RECURRENCE-ID` is the clearest case: a reply about one
/// occurrence of a series carries the same `RECURRENCE-ID`, including its
/// `TZID`/`RANGE` parameters, or the organizer's client applies it to the wrong
/// occurrence. Re-serialising from a parsed value would drop exactly the
/// parameters that make it unambiguous.
///
/// [propertyNames] are matched case-insensitively against the property name
/// only, so a name is not confused with one it prefixes: `DTSTART` does not
/// match `DTSTART;TZID=…`'s neighbour `DTSTAMP`, and asking for `RRULE` will
/// not pick up an `X-RRULE-SOURCE`.
List<String> icsPassthroughLines(
  String originalIcs,
  Set<String> propertyNames,
) {
  final wanted = propertyNames.map((n) => n.toUpperCase()).toSet();
  final unfolded = originalIcs.replaceAll(RegExp(r'\r?\n[ \t]'), '');
  return unfolded
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => wanted.contains(_propertyNameOf(l)))
      .toList();
}

/// The property name at the head of a content line — everything before the
/// first `;` (parameters) or `:` (value), upper-cased. Empty for a line with
/// neither.
String _propertyNameOf(String line) {
  final end = line.indexOf(RegExp('[;:]'));
  if (end <= 0) return '';
  return line.substring(0, end).toUpperCase();
}
