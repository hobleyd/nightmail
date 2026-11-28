import 'package:equatable/equatable.dart';

import 'email.dart';

/// The stretch of a folder, by date, that one listed page answers for — what
/// the cache write may *replace* rather than merely add to.
///
/// A page of a folder listing is the truth about the messages in its window and
/// says nothing about the rest. Replacing the whole folder with it (what every
/// first page used to do) threw away every older row the user had scrolled
/// through, so a folder never held more than one page; replacing nothing let a
/// message deleted elsewhere sit in the cache forever. See
/// `lib/presentation/blocs/email_list/CLAUDE.md`, "A Folder's Cache Is Replaced
/// a Window at a Time".
///
/// Dates are *thread* keys: each thread on the page is dated by its newest row
/// (any folder's copy the listing carried), and the window starts at the
/// oldest of those. That is Gmail's listing order exactly (threads by their
/// latest message) and a slightly *newer* bound than Graph's (messages by their
/// own date) when a thread's Sent reply is newer than its listed message — the
/// safe direction, since a narrower window replaces less.
class ListingWindow extends Equatable {
  /// The folder's newest page: it answers for everything from [from] to now.
  const ListingWindow.top({this.from, this.listedIds = const {}, this.dateOrdered = true})
      : to = null;

  /// A page further down: it answers for [from] up to and including [to], the
  /// start of the page above it.
  const ListingWindow.continuing({
    this.from,
    required DateTime this.to,
    this.listedIds = const {},
    this.dateOrdered = true,
  });

  /// The oldest thread key on the page, or null when the page reached the end
  /// of the folder (it answers for everything older too).
  final DateTime? from;

  /// The newest date the page answers for; null for the folder's top page.
  final DateTime? to;

  /// The ids the *server* listed — before reconciliation put back a moved
  /// message it has not caught up with. Only these may prove that a top page
  /// joins onto what the cache already holds (see [FolderCoverage]).
  final Set<String> listedIds;

  /// Whether the listing is in date order (Graph, Gmail), so the window's
  /// dates describe the stretch of the folder it covers. Such a listing also
  /// carries every message of each thread on the page, which is what lets the
  /// replace leave alone a thread that straddles the window's edge.
  ///
  /// False for IMAP, which lists by UID: there a top page replaces the whole
  /// folder, a page further down only adds, and no coverage is kept — the
  /// paging every folder had before the cache kept more than a page.
  final bool dateOrdered;

  bool get isTop => to == null;

  /// The window a page of [pageSize] listed from the top of [folderId] answers
  /// for.
  factory ListingWindow.topOf(
    List<Email> page, {
    required String? folderId,
    required int pageSize,
    int? listedCount,
    bool dateOrdered = true,
  }) =>
      ListingWindow.top(
        from: listingWindowStart(page,
            folderId: folderId, pageSize: pageSize, listedCount: listedCount),
        listedIds: {for (final e in page) e.id},
        dateOrdered: dateOrdered,
      );

  /// The window a page of [pageSize] listed below [to] answers for.
  factory ListingWindow.continuingOf(
    List<Email> page, {
    required String? folderId,
    required int pageSize,
    required DateTime to,
    int? listedCount,
    bool dateOrdered = true,
  }) =>
      ListingWindow.continuing(
        from: listingWindowStart(page,
            folderId: folderId, pageSize: pageSize, listedCount: listedCount),
        to: to,
        listedIds: {for (final e in page) e.id},
        dateOrdered: dateOrdered,
      );

  @override
  List<Object?> get props => [from, to, listedIds, dateOrdered];
}

/// The date a listed page's window starts at, or null when the page is not
/// full — the folder ends inside it.
///
/// [listedCount] is how many items the server listed (see `ListedPage`) and is
/// the only reliable answer to "was the page full". Without it the page is
/// judged generously, because a page wrongly taken as full only replaces less:
/// either [pageSize] of the folder's own messages (Graph, IMAP, counting a
/// thread's older same-folder copies the expansion brought) or [pageSize]
/// threads (Gmail lists threads). A page wrongly taken as *short* claims the
/// folder ends there and drops everything older.
DateTime? listingWindowStart(
  List<Email> page, {
  required String? folderId,
  required int pageSize,
  int? listedCount,
}) {
  if (page.isEmpty) return null;
  final keys = threadKeys(page);
  final full = listedCount != null
      ? listedCount >= pageSize
      : page.where((e) => e.isInFolder(folderId)).length >= pageSize ||
          keys.length >= pageSize;
  if (!full) return null;
  return keys.values.reduce((a, b) => a.isBefore(b) ? a : b);
}

/// Each thread on [rows] → its newest row's date. A row with no conversation
/// is a thread of its own.
Map<String, DateTime> threadKeys(Iterable<Email> rows) {
  final keys = <String, DateTime>{};
  for (final e in rows) {
    final key = e.conversationId ?? e.id;
    final current = keys[key];
    if (current == null || e.receivedDateTime.isAfter(current)) {
      keys[key] = e.receivedDateTime;
    }
  }
  return keys;
}

/// How much of a folder the cache can vouch for: every message dated from
/// [coveredFrom] to now is in it (as of the listings that wrote it), or the
/// whole folder when [complete].
///
/// The cache is only shown beyond the first page within this coverage. Rows
/// below it can be islands — a message moved in from another folder, filed
/// under its destination at once — and the network listing continues *from*
/// [coveredFrom], never from the oldest row on screen, or the stretch between
/// an island and the real edge would never be listed.
class FolderCoverage extends Equatable {
  const FolderCoverage({
    this.coveredFrom,
    this.complete = false,
    this.lastFullPassAt,
  });

  final DateTime? coveredFrom;
  final bool complete;

  /// When the offline backfill last walked the folder end to end — the
  /// monthly re-check's clock. Null when it never has.
  final DateTime? lastFullPassAt;

  /// Whether a cached thread dated [key] lies inside the coverage.
  bool covers(DateTime key) =>
      complete || (coveredFrom != null && !key.isBefore(coveredFrom!));

  @override
  List<Object?> get props => [coveredFrom, complete, lastFullPassAt];
}

/// A position in a folder's cache, read a window of threads at a time: the
/// thread key of the last thread read, and its key string to break ties
/// between threads dated to the same millisecond.
class CacheCursor extends Equatable {
  const CacheCursor({required this.threadDate, required this.threadKey});

  final DateTime threadDate;
  final String threadKey;

  @override
  List<Object?> get props => [threadDate, threadKey];
}

/// The position after the oldest thread of [rows] — where the cache window
/// that follows them starts. [rows] must hold every cached row of each thread
/// in it (a window read does), so the keys match what the cache dates by.
CacheCursor? lastThreadOf(Iterable<Email> rows) {
  CacheCursor? last;
  threadKeys(rows).forEach((key, date) {
    if (last == null ||
        date.isBefore(last!.threadDate) ||
        (date == last!.threadDate && key.compareTo(last!.threadKey) < 0)) {
      last = CacheCursor(threadDate: date, threadKey: key);
    }
  });
  return last;
}

/// One window of a folder's cache: its rows, newest first, and where the next
/// window starts (null when nothing older is cached in range).
class CachedWindow {
  const CachedWindow({required this.emails, required this.next});

  final List<Email> emails;
  final CacheCursor? next;
}

/// Where the offline backfill is in walking one folder: the listing it is
/// paging is the folder's messages older than [before] (fixed for the whole
/// walk, so a provider that lists by thread cannot stall on long threads that
/// keep re-appearing), [offset] pages into it, and [windowEnd] is the start of
/// the last page it wrote — the top of the next page's window. A [full] walk
/// is the monthly re-check from the top; otherwise it is filling the stretch
/// below the coverage.
class FolderWalk extends Equatable {
  const FolderWalk({
    required this.before,
    required this.offset,
    required this.windowEnd,
    required this.full,
  });

  final DateTime before;
  final int offset;
  final DateTime windowEnd;
  final bool full;

  @override
  List<Object?> get props => [before, offset, windowEnd, full];
}

/// What one page of the offline backfill's walk brought: how many rows, and
/// the start of the window it was written over — where the next page's window
/// ends. A null [windowStart] means the walk reached the bottom of the folder.
class SyncedPage extends Equatable {
  const SyncedPage({required this.rows, required this.windowStart});

  final int rows;
  final DateTime? windowStart;

  bool get reachedEnd => windowStart == null;

  @override
  List<Object?> get props => [rows, windowStart];
}
