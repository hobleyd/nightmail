import '../../domain/entities/calendar_event.dart';

/// The column a calendar tile occupies within its overlap cluster, and how many
/// columns that cluster needs. `index`/`total` translate directly into the
/// tile's horizontal offset and width.
class ColumnSpan {
  const ColumnSpan({required this.index, required this.total});

  final int index;
  final int total;

  /// A tile that has the day column to itself.
  static const full = ColumnSpan(index: 0, total: 1);
}

/// Assigns each of [events] a column so that events overlapping in time tile
/// side-by-side instead of stacking on top of each other.
///
/// Returns one [ColumnSpan] per event, positionally matching [events] — callers
/// index by position rather than by event ID so duplicate IDs (the same meeting
/// arriving from two accounts, say) can't collapse two tiles into one column.
List<ColumnSpan> computeOverlapLayout(List<CalendarEvent> events) {
  final spans = List<ColumnSpan>.filled(events.length, ColumnSpan.full);
  if (events.isEmpty) return spans;

  bool overlaps(CalendarEvent a, CalendarEvent b) =>
      a.start.isBefore(b.end) && b.start.isBefore(a.end);

  final byStart = List.generate(events.length, (i) => i)
    ..sort((a, b) => events[a].start.compareTo(events[b].start));

  // Build connected-component clusters: two events share a cluster if they
  // overlap, or both overlap something that links them.
  final clusters = <List<int>>[];
  for (final i in byStart) {
    final touching = clusters
        .where((c) => c.any((j) => overlaps(events[j], events[i])))
        .toList();
    if (touching.isEmpty) {
      clusters.add([i]);
    } else {
      final merged = touching.expand((c) => c).toList()..add(i);
      for (final c in touching) {
        clusters.remove(c);
      }
      clusters.add(merged);
    }
  }

  for (final cluster in clusters) {
    cluster.sort((a, b) => events[a].start.compareTo(events[b].start));

    // Greedy assignment: each event takes the first column whose last event has
    // already ended. Compare whole instants, not time-of-day — an event running
    // past midnight (a multi-day hotel booking, an overnight flight) ends on a
    // later date, and a time-of-day comparison reads that end as *earlier* than
    // a later event's start, so the column gets reused and the two tiles stack.
    final colEnds = <DateTime>[];
    final columns = <int, int>{};

    for (final i in cluster) {
      final e = events[i];
      var col = colEnds.indexWhere((end) => !e.start.isBefore(end));
      if (col == -1) {
        col = colEnds.length;
        colEnds.add(e.end);
      } else {
        colEnds[col] = e.end;
      }
      columns[i] = col;
    }

    for (final i in cluster) {
      spans[i] = ColumnSpan(index: columns[i]!, total: colEnds.length);
    }
  }

  return spans;
}
