import 'dart:math' as math;

// The email list's keyboard and Shift-click selection, kept free of widgets so
// it can be tested on its own. Every function takes [rowIds]: the ids of the
// rows a selection can land on, in list order — one per single message and one
// per thread header, *without* the echo row a thread draws for its own message
// (it shares the header's id; see `_isNavigable` in email_list_panel.dart).
//
// Rows are tracked by id, never by index: the poller inserts rows at the top
// and expanding a thread inserts rows in the middle, and either would leave a
// remembered index pointing at a different message.

/// The row [step] rows away from [fromId], or null when the list runs out or
/// [fromId] is no longer on it. With nothing to step from, Down lands on the
/// first row and Up on nothing.
String? stepRow(List<String> rowIds, String? fromId, int step) {
  if (rowIds.isEmpty) return null;
  if (fromId == null) return step > 0 ? rowIds.first : null;
  final from = rowIds.indexOf(fromId);
  if (from == -1) return null;
  final to = from + step;
  return to >= 0 && to < rowIds.length ? rowIds[to] : null;
}

/// [base] plus every row from [anchorId] to [cursorId] inclusive, in either
/// direction.
///
/// Recomputed from the anchor on every Shift-arrow or Shift-click rather than
/// added to, so stepping back towards the anchor shrinks the range and stepping
/// past it flips it to the other side. [base] is what was already selected
/// when the anchor was set (a Cmd-click picks the anchor *and* keeps what it
/// picked before), so a range never eats an earlier pick.
///
/// An anchor that has left the list (deleted, or a refresh dropped it) leaves
/// nothing to span from, so the range is the cursor row alone.
Set<String> rangeSelection(
  List<String> rowIds, {
  required String anchorId,
  required String cursorId,
  Set<String> base = const {},
}) {
  final cursor = rowIds.indexOf(cursorId);
  if (cursor == -1) return Set.of(base);
  final anchor = rowIds.indexOf(anchorId);
  if (anchor == -1) return {...base, cursorId};
  final lo = math.min(anchor, cursor);
  final hi = math.max(anchor, cursor);
  return {...base, ...rowIds.sublist(lo, hi + 1)};
}
