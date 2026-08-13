import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/utils/online_meeting_url.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/calendar_event_attendee.dart';
import '../../../domain/entities/calendar_recurrence.dart';
import '../../../infrastructure/cache/cache_encryption_service.dart';
import '../../database/app_database.dart';
import 'calendar_local_datasource.dart';

class CalendarLocalDatasourceImpl implements CalendarLocalDatasource {
  const CalendarLocalDatasourceImpl({
    required this._database,
    required this._encryption,
  });

  final AppDatabase _database;
  final CacheEncryptionService _encryption;

  @override
  Future<List<CalendarEvent>> getCachedEvents({
    required String accountId,
    required DateTime start,
    required DateTime end,
  }) async {
    final startMs = start.toUtc().millisecondsSinceEpoch;
    final endMs = end.toUtc().millisecondsSinceEpoch;

    final rows = await (_database.select(_database.cachedCalendarEvents)
          ..where((t) =>
              t.accountId.equals(accountId) &
              // Overlap, not containment: an event that began before the range
              // and runs into it is on those days too.
              t.startMs.isSmallerThanValue(endMs) &
              t.endMs.isBiggerThanValue(startMs))
          ..orderBy([(t) => OrderingTerm.asc(t.startMs)]))
        .get();

    return _decodeRows(rows);
  }

  @override
  Future<void> cacheEvents({
    required String accountId,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<CalendarEvent> events,
  }) async {
    final windowStartMs = windowStart.toUtc().millisecondsSinceEpoch;
    final windowEndMs = windowEnd.toUtc().millisecondsSinceEpoch;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Encrypt outside the transaction — each call is an async KDF/AES round and
    // holding a write transaction open across them would block every other
    // reader for the duration.
    final companions = await Future.wait(
      events.map((e) => _toCompanion(accountId, e, now)),
    );

    await _database.transaction(() async {
      await (_database.delete(_database.cachedCalendarEvents)
            ..where((t) =>
                t.accountId.equals(accountId) &
                t.startMs.isSmallerThanValue(windowEndMs) &
                t.endMs.isBiggerThanValue(windowStartMs)))
          .go();

      await _database.batch((batch) {
        for (final companion in companions) {
          batch.insert(
            _database.cachedCalendarEvents,
            companion,
            mode: InsertMode.insertOrReplace,
          );
        }
      });
    });
  }

  @override
  Future<CalendarEvent?> getCachedEventById({
    required String accountId,
    required String eventId,
  }) async {
    final row = await (_database.select(_database.cachedCalendarEvents)
          ..where((t) =>
              t.accountId.equals(accountId) & t.eventId.equals(eventId)))
        .getSingleOrNull();
    if (row == null) return null;
    return _decodeRow(row);
  }

  @override
  Future<CalendarEvent?> getCachedEventByICalUid({
    required String accountId,
    required String iCalUid,
  }) async {
    // A recurring series shares one UID across every occurrence, so this can
    // match several rows. The earliest still-relevant one is the copy an
    // invitation refers to.
    final row = await (_database.select(_database.cachedCalendarEvents)
          ..where((t) =>
              t.accountId.equals(accountId) & t.iCalUid.equals(iCalUid))
          ..orderBy([(t) => OrderingTerm.asc(t.startMs)])
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return _decodeRow(row);
  }

  @override
  Future<void> upsertEvent({
    required String accountId,
    required CalendarEvent event,
  }) async {
    final companion = await _toCompanion(
      accountId,
      event,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _database
        .into(_database.cachedCalendarEvents)
        .insert(companion, mode: InsertMode.insertOrReplace);
  }

  @override
  Future<void> deleteEvent({
    required String accountId,
    required String eventId,
  }) async {
    await (_database.delete(_database.cachedCalendarEvents)
          ..where((t) =>
              t.accountId.equals(accountId) & t.eventId.equals(eventId)))
        .go();
  }

  @override
  Future<void> deleteSeries({
    required String accountId,
    required String eventId,
    String? seriesMasterId,
  }) async {
    // The master id is the one occurrences carry; when the caller only knows
    // the clicked occurrence, read its master out of the cache first so the
    // rest of the series is still found.
    final masterId = seriesMasterId ??
        (await getCachedEventById(accountId: accountId, eventId: eventId))
            ?.seriesMasterId;

    await (_database.delete(_database.cachedCalendarEvents)
          ..where((t) {
            final self = t.eventId.equals(eventId);
            if (masterId == null) return t.accountId.equals(accountId) & self;
            return t.accountId.equals(accountId) &
                (self |
                    t.eventId.equals(masterId) |
                    t.seriesMasterId.equals(masterId));
          }))
        .go();
  }

  @override
  Future<int> pruneEventsEndingBefore({
    required String accountId,
    required DateTime before,
  }) {
    return (_database.delete(_database.cachedCalendarEvents)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.endMs.isSmallerThanValue(before.toUtc().millisecondsSinceEpoch)))
        .go();
  }

  @override
  Future<void> clearEventsForAccount(String accountId) async {
    await (_database.delete(_database.cachedCalendarEvents)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
  }

  @override
  Future<List<String>> cachedEventAccountIds() async {
    final query = _database.selectOnly(_database.cachedCalendarEvents, distinct: true)
      ..addColumns([_database.cachedCalendarEvents.accountId]);
    final rows = await query.get();
    return rows
        .map((r) => r.read(_database.cachedCalendarEvents.accountId))
        .whereType<String>()
        .toList();
  }

  Future<CachedCalendarEventsCompanion> _toCompanion(
    String accountId,
    CalendarEvent event,
    int cachedAtMs,
  ) async {
    final encrypted = await _encryption.encrypt(jsonEncode(_toJson(event)));
    return CachedCalendarEventsCompanion.insert(
      accountId: accountId,
      eventId: event.id,
      startMs: event.start.toUtc().millisecondsSinceEpoch,
      endMs: event.end.toUtc().millisecondsSinceEpoch,
      iCalUid: Value(event.iCalUid),
      seriesMasterId: Value(event.seriesMasterId),
      cachedAtMs: cachedAtMs,
      encryptedData: encrypted,
    );
  }

  Future<List<CalendarEvent>> _decodeRows(
      List<CachedCalendarEventRow> rows) async {
    final events = <CalendarEvent>[];
    for (final row in rows) {
      final event = await _decodeRow(row);
      // A row that cannot be decoded (key rotated, blob truncated) is dropped
      // rather than failing the whole week — see [_decodeRow].
      if (event != null) events.add(event);
    }
    return events;
  }

  Future<CalendarEvent?> _decodeRow(CachedCalendarEventRow row) async {
    try {
      final json =
          jsonDecode(await _encryption.decrypt(row.encryptedData))
              as Map<String, dynamic>;
      return _fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _toJson(CalendarEvent e) => {
        'id': e.id,
        'subject': e.subject,
        'start': e.start.toUtc().toIso8601String(),
        'end': e.end.toUtc().toIso8601String(),
        'isAllDay': e.isAllDay,
        'iCalUid': e.iCalUid,
        'location': e.location,
        'onlineMeetingUrl': e.onlineMeetingUrl,
        'bodyPreview': e.bodyPreview,
        'status': e.status.name,
        'participation': e.participation.name,
        'isOrganizer': e.isOrganizer,
        'organizerEmail': e.organizerEmail,
        'organizerName': e.organizerName,
        'timezone': e.timezone,
        'attendees': e.attendees.map(_attendeeToJson).toList(),
        'recurrence': _recurrenceToJson(e.recurrence),
        'reminderMinutes': e.reminderMinutes,
        'seriesMasterId': e.seriesMasterId,
      };

  static CalendarEvent _fromJson(Map<String, dynamic> j) {
    // Blobs written before the join link had a field of its own hold it in
    // `location`. Splitting on read keeps those meetings joinable — and keeps
    // the URL out of the event form's location box — without a migration pass
    // over the cache, which the next sync rewrites anyway.
    final split = splitMeetingLocation(
      rawLocation: j['location'] as String?,
      onlineMeetingUrl: j['onlineMeetingUrl'] as String?,
    );
    return CalendarEvent(
        id: j['id'] as String,
        subject: j['subject'] as String? ?? '(No title)',
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        isAllDay: j['isAllDay'] as bool? ?? false,
        iCalUid: j['iCalUid'] as String?,
        location: split.location,
        onlineMeetingUrl: split.onlineMeetingUrl,
        bodyPreview: j['bodyPreview'] as String?,
        status: _enumByName(
          CalendarEventStatus.values,
          j['status'] as String?,
          CalendarEventStatus.busy,
        ),
        participation: _enumByName(
          MeetingParticipation.values,
          j['participation'] as String?,
          MeetingParticipation.none,
        ),
        isOrganizer: j['isOrganizer'] as bool? ?? false,
        // Absent from blobs written before the field existed; the next sync
        // pass rewrites the row with it, so no migration is needed.
        organizerEmail: j['organizerEmail'] as String?,
        organizerName: j['organizerName'] as String?,
        timezone: j['timezone'] as String?,
        attendees: (j['attendees'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(_attendeeFromJson)
            .toList(),
        recurrence:
            _recurrenceFromJson(j['recurrence'] as Map<String, dynamic>?),
        reminderMinutes: j['reminderMinutes'] as int?,
        seriesMasterId: j['seriesMasterId'] as String?,
      );
  }

  /// Tolerant enum read: a blob written by a build with a different set of
  /// enum names must not make the whole event undecodable.
  static T _enumByName<T extends Enum>(
      List<T> values, String? name, T fallback) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  static Map<String, dynamic> _attendeeToJson(CalendarEventAttendee a) => {
        'email': a.email,
        'displayName': a.displayName,
        'responseStatus': a.responseStatus.name,
        'isResource': a.isResource,
      };

  static CalendarEventAttendee _attendeeFromJson(Map<String, dynamic> j) =>
      CalendarEventAttendee(
        email: j['email'] as String? ?? '',
        displayName: j['displayName'] as String?,
        responseStatus: _enumByName(
          AttendeeResponseStatus.values,
          j['responseStatus'] as String?,
          AttendeeResponseStatus.none,
        ),
        // Absent in blobs written before rooms were bookable. Those events show
        // their rooms as guests until the next sync pass rewrites the row from
        // the provider, which is the same self-healing the cache relies on
        // everywhere else.
        isResource: j['isResource'] as bool? ?? false,
      );

  static Map<String, dynamic>? _recurrenceToJson(CalendarRecurrence? r) {
    if (r == null) return null;
    return {
      'frequency': r.frequency.name,
      'interval': r.interval,
      'daysOfWeek': r.daysOfWeek,
      'endDate': r.endDate?.toIso8601String(),
      'count': r.count,
    };
  }

  static CalendarRecurrence? _recurrenceFromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final endDate = j['endDate'] as String?;
    return CalendarRecurrence(
      frequency: _enumByName(
        RecurrenceFrequency.values,
        j['frequency'] as String?,
        RecurrenceFrequency.daily,
      ),
      interval: j['interval'] as int? ?? 1,
      daysOfWeek: (j['daysOfWeek'] as List<dynamic>?)?.cast<int>(),
      endDate: endDate == null ? null : DateTime.tryParse(endDate),
      count: j['count'] as int?,
    );
  }
}
