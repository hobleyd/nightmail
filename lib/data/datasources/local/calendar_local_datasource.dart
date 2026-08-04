import '../../../domain/entities/calendar_event.dart';

/// Local cache of calendar events, so the calendar can paint before the
/// provider has answered — and keep painting when it never does.
///
/// Every method is account-scoped and range-based rather than page-based: a
/// calendar is asked "what is on between these two instants", and a meeting
/// belongs to a range if it *overlaps* it, so a multi-day event is returned for
/// every week it spans.
abstract interface class CalendarLocalDatasource {
  /// Cached events for [accountId] overlapping \[[start], [end]), ordered by
  /// start ascending. Empty when nothing is cached for that range.
  Future<List<CalendarEvent>> getCachedEvents({
    required String accountId,
    required DateTime start,
    required DateTime end,
  });

  /// Replaces the cached contents of \[[windowStart], [windowEnd]) for
  /// [accountId] with [events].
  ///
  /// Replace, not merge: a meeting cancelled or moved away by someone else is
  /// only detectable by its *absence* from a fresh fetch of the same window, so
  /// upserting alone would leave it on screen forever. Rows overlapping the
  /// window but outside it are rewritten too when the fetch returns them, which
  /// is what providers do for a calendar view.
  ///
  /// [events] may be empty — a genuinely empty week has to clear the week.
  Future<void> cacheEvents({
    required String accountId,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<CalendarEvent> events,
  });

  /// The cached event with [eventId], or null when it isn't cached.
  Future<CalendarEvent?> getCachedEventById({
    required String accountId,
    required String eventId,
  });

  /// The cached event whose iCalendar UID is [iCalUid], or null when there
  /// isn't one. Used by the invitation-side mutations, which know a meeting
  /// only by the `UID` in the ICS attached to the mail.
  Future<CalendarEvent?> getCachedEventByICalUid({
    required String accountId,
    required String iCalUid,
  });

  /// Inserts or replaces a single event. Used to apply an optimistic mutation
  /// and to fold a newly created event into the cache without a full resync.
  Future<void> upsertEvent({
    required String accountId,
    required CalendarEvent event,
  });

  /// Removes the cached event with [eventId]. No-ops when it isn't cached.
  Future<void> deleteEvent({
    required String accountId,
    required String eventId,
  });

  /// Removes every cached occurrence of a recurring series, given any of its
  /// ids — the clicked occurrence's [eventId] and, when known, the
  /// [seriesMasterId]. Occurrences are matched on either, because providers
  /// disagree about whether the master's own id appears as an occurrence.
  Future<void> deleteSeries({
    required String accountId,
    required String eventId,
    String? seriesMasterId,
  });

  /// Drops cached events that finished before [before] — the retention cut-off.
  /// Returns the number of rows removed.
  Future<int> pruneEventsEndingBefore({
    required String accountId,
    required DateTime before,
  });

  /// Drops every cached event for [accountId]. Called when an account is
  /// removed or the user clears cached data.
  Future<void> clearEventsForAccount(String accountId);

  /// The account ids that currently have cached events. Lets the sync service
  /// clean up after an account that has since been removed.
  Future<List<String>> cachedEventAccountIds();
}
