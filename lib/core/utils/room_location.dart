/// Taking booked rooms back out of a provider's free-text `location`.
///
/// Both providers name a booked room in `location` as well as inviting it
/// (Graph mirrors `locations[0]` into it; Google has only the one string), and
/// the save path names it there again. Anything that hands a meeting's
/// location back to a save therefore has to strip the rooms first, or every
/// round trip prepends another copy of the room's name.
library;

/// [location] without the segments that are just one of [roomLabels] — a
/// room's name or address, matched case-insensitively.
///
/// Segments are split on `,`/`;` and re-joined with `, `. A location with
/// nothing to strip is returned exactly as written.
String stripRoomNames(String location, Iterable<String?> roomLabels) {
  if (location.isEmpty) return location;
  final labels = {
    for (final l in roomLabels)
      if (l != null && l.trim().isNotEmpty) l.trim().toLowerCase(),
  };
  if (labels.isEmpty) return location;
  final segments = location.split(RegExp(r'\s*[;,]\s*'));
  final kept = segments
      .where((segment) =>
          segment.trim().isNotEmpty &&
          !labels.contains(segment.trim().toLowerCase()))
      .toList();
  if (kept.length == segments.length) return location;
  return kept.join(', ');
}
