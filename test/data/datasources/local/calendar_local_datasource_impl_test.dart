// Drift round-trip tests for the calendar cache. The real in-memory database is
// the unit under test: the range predicates (overlap, not containment), the
// replace-a-window semantics and the series delete are all SQL, and none of it
// survives being mocked.

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/calendar_local_datasource.dart';
import 'package:nightmail/data/datasources/local/calendar_local_datasource_impl.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';

// Bypasses secure-storage platform channels — these tests need round-trip
// fidelity, not real encryption.
class _PlaintextEncryption extends CacheEncryptionService {
  _PlaintextEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async => plaintext;

  @override
  Future<String> decrypt(String stored) async => stored;
}

void main() {
  late AppDatabase db;
  late CalendarLocalDatasource ds;

  const accountId = 'acc1';

  /// Monday 8 June 2026, 09:00 UTC, plus [dayOffset] days.
  DateTime at(int dayOffset, int hour) =>
      DateTime.utc(2026, 6, 8 + dayOffset, hour);

  CalendarEvent event(
    String id, {
    required DateTime start,
    required DateTime end,
    String? iCalUid,
    String? seriesMasterId,
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Meeting $id',
        start: start,
        end: end,
        isAllDay: false,
        iCalUid: iCalUid,
        seriesMasterId: seriesMasterId,
      );

  Future<void> seed(
    List<CalendarEvent> events, {
    required DateTime windowStart,
    required DateTime windowEnd,
    String account = accountId,
  }) =>
      ds.cacheEvents(
        accountId: account,
        windowStart: windowStart,
        windowEnd: windowEnd,
        events: events,
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ds = CalendarLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
    );
  });

  tearDown(() => db.close());

  group('cacheEvents / getCachedEvents', () {
    test('round-trips every field of an event', () async {
      final original = CalendarEvent(
        id: 'e1',
        subject: 'Design review',
        start: at(0, 9),
        end: at(0, 10),
        isAllDay: false,
        iCalUid: 'uid-1',
        location: 'https://meet.example/abc',
        bodyPreview: 'Agenda attached',
        status: CalendarEventStatus.tentative,
        participation: MeetingParticipation.needsAction,
        isOrganizer: true,
        timezone: 'Australia/Sydney',
        attendees: const [
          CalendarEventAttendee(
            email: 'bob@corp.com',
            displayName: 'Bob',
            responseStatus: AttendeeResponseStatus.declined,
          ),
        ],
        recurrence: CalendarRecurrence(
          frequency: RecurrenceFrequency.weekly,
          interval: 2,
          daysOfWeek: const [1, 3],
          endDate: DateTime.utc(2026, 12, 1),
        ),
        reminderMinutes: 15,
        seriesMasterId: 'master-1',
      );

      await seed([original], windowStart: at(0, 0), windowEnd: at(1, 0));
      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));

      final e = read.single;
      expect(e.id, 'e1');
      expect(e.subject, 'Design review');
      expect(e.start, original.start);
      expect(e.end, original.end);
      expect(e.iCalUid, 'uid-1');
      expect(e.location, 'https://meet.example/abc');
      expect(e.bodyPreview, 'Agenda attached');
      expect(e.status, CalendarEventStatus.tentative);
      expect(e.participation, MeetingParticipation.needsAction);
      expect(e.isOrganizer, isTrue);
      expect(e.timezone, 'Australia/Sydney');
      expect(e.attendees.single.email, 'bob@corp.com');
      expect(e.attendees.single.displayName, 'Bob');
      expect(
          e.attendees.single.responseStatus, AttendeeResponseStatus.declined);
      expect(e.recurrence!.frequency, RecurrenceFrequency.weekly);
      expect(e.recurrence!.interval, 2);
      expect(e.recurrence!.daysOfWeek, [1, 3]);
      expect(e.recurrence!.endDate, DateTime.utc(2026, 12, 1));
      expect(e.reminderMinutes, 15);
      expect(e.seriesMasterId, 'master-1');
    });

    test('returns events ordered by start', () async {
      await seed([
        event('late', start: at(0, 15), end: at(0, 16)),
        event('early', start: at(0, 9), end: at(0, 10)),
        event('mid', start: at(0, 12), end: at(0, 13)),
      ], windowStart: at(0, 0), windowEnd: at(1, 0));

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));

      expect(read.map((e) => e.id), ['early', 'mid', 'late']);
    });

    test('a range matches on overlap, so a spanning event is in every week',
        () async {
      // A five-day event starting the week before the range being asked about.
      await seed(
        [event('conference', start: at(-3, 9), end: at(2, 17))],
        windowStart: at(-7, 0),
        windowEnd: at(7, 0),
      );

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));

      expect(read.single.id, 'conference');
    });

    test('an event that ends exactly at the range start is excluded', () async {
      await seed(
        [event('before', start: at(-1, 8), end: at(0, 0))],
        windowStart: at(-7, 0),
        windowEnd: at(7, 0),
      );

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));

      expect(read, isEmpty);
    });

    test('caching a window removes meetings that have gone from it', () async {
      await seed([
        event('kept', start: at(0, 9), end: at(0, 10)),
        event('cancelled-elsewhere', start: at(0, 14), end: at(0, 15)),
      ], windowStart: at(0, 0), windowEnd: at(1, 0));

      // A later fetch of the same window no longer lists the second meeting.
      await seed(
        [event('kept', start: at(0, 9), end: at(0, 10))],
        windowStart: at(0, 0),
        windowEnd: at(1, 0),
      );

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));
      expect(read.map((e) => e.id), ['kept']);
    });

    test('caching a window leaves meetings outside it alone', () async {
      await seed(
        [event('next-week', start: at(8, 9), end: at(8, 10))],
        windowStart: at(7, 0),
        windowEnd: at(14, 0),
      );
      await seed(
        [event('this-week', start: at(0, 9), end: at(0, 10))],
        windowStart: at(0, 0),
        windowEnd: at(7, 0),
      );

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(14, 0));
      expect(read.map((e) => e.id), ['this-week', 'next-week']);
    });

    test('an empty fetch clears a genuinely empty week', () async {
      await seed([event('e1', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0));
      await seed([], windowStart: at(0, 0), windowEnd: at(1, 0));

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));
      expect(read, isEmpty);
    });

    test('accounts do not see each other\'s meetings', () async {
      await seed([event('mine', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0));
      await seed([event('theirs', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0), account: 'acc2');

      final mine = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));
      expect(mine.map((e) => e.id), ['mine']);
      // Replacing one account's window must not have touched the other's.
      final theirs = await ds.getCachedEvents(
          accountId: 'acc2', start: at(0, 0), end: at(1, 0));
      expect(theirs.map((e) => e.id), ['theirs']);
    });
  });

  group('lookups', () {
    test('getCachedEventById finds and misses correctly', () async {
      await seed([event('e1', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0));

      expect(
          (await ds.getCachedEventById(accountId: accountId, eventId: 'e1'))
              ?.id,
          'e1');
      expect(
          await ds.getCachedEventById(accountId: accountId, eventId: 'nope'),
          isNull);
    });

    test('getCachedEventByICalUid returns the earliest of a shared UID',
        () async {
      // Every occurrence of a series carries the same iCalendar UID.
      await seed([
        event('occ-2', start: at(7, 9), end: at(7, 10), iCalUid: 'uid-1'),
        event('occ-1', start: at(0, 9), end: at(0, 10), iCalUid: 'uid-1'),
      ], windowStart: at(0, 0), windowEnd: at(14, 0));

      final found = await ds.getCachedEventByICalUid(
          accountId: accountId, iCalUid: 'uid-1');
      expect(found?.id, 'occ-1');
    });
  });

  group('deletes', () {
    test('deleteEvent removes one meeting', () async {
      await seed([
        event('e1', start: at(0, 9), end: at(0, 10)),
        event('e2', start: at(0, 11), end: at(0, 12)),
      ], windowStart: at(0, 0), windowEnd: at(1, 0));

      await ds.deleteEvent(accountId: accountId, eventId: 'e1');

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));
      expect(read.map((e) => e.id), ['e2']);
    });

    test('deleteSeries removes every occurrence given the master id', () async {
      await seed([
        event('occ-1', start: at(0, 9), end: at(0, 10),
            seriesMasterId: 'master-1'),
        event('occ-2', start: at(7, 9), end: at(7, 10),
            seriesMasterId: 'master-1'),
        event('unrelated', start: at(1, 9), end: at(1, 10)),
      ], windowStart: at(0, 0), windowEnd: at(14, 0));

      await ds.deleteSeries(
          accountId: accountId, eventId: 'occ-1', seriesMasterId: 'master-1');

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(14, 0));
      expect(read.map((e) => e.id), ['unrelated']);
    });

    test('deleteSeries reads the master off the occurrence when not given it',
        () async {
      await seed([
        event('occ-1', start: at(0, 9), end: at(0, 10),
            seriesMasterId: 'master-1'),
        event('occ-2', start: at(7, 9), end: at(7, 10),
            seriesMasterId: 'master-1'),
      ], windowStart: at(0, 0), windowEnd: at(14, 0));

      await ds.deleteSeries(accountId: accountId, eventId: 'occ-1');

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(14, 0));
      expect(read, isEmpty);
    });

    test('deleteSeries also removes the master row itself', () async {
      await seed([
        event('master-1', start: at(0, 9), end: at(0, 10)),
        event('occ-2', start: at(7, 9), end: at(7, 10),
            seriesMasterId: 'master-1'),
      ], windowStart: at(0, 0), windowEnd: at(14, 0));

      await ds.deleteSeries(
          accountId: accountId, eventId: 'occ-2', seriesMasterId: 'master-1');

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(14, 0));
      expect(read, isEmpty);
    });
  });

  group('retention', () {
    test('pruneEventsEndingBefore drops what finished before the cut-off',
        () async {
      await seed([
        event('old', start: at(-20, 9), end: at(-20, 10)),
        event('borderline', start: at(-14, 9), end: at(-14, 10)),
        event('recent', start: at(-2, 9), end: at(-2, 10)),
        event('future', start: at(3, 9), end: at(3, 10)),
      ], windowStart: at(-30, 0), windowEnd: at(30, 0));

      final removed = await ds.pruneEventsEndingBefore(
        accountId: accountId,
        // Everything that finished before 14 days ago goes.
        before: at(-14, 0),
      );

      expect(removed, 1);
      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(-30, 0), end: at(30, 0));
      expect(read.map((e) => e.id), ['borderline', 'recent', 'future']);
    });

    test('pruning is scoped to one account', () async {
      await seed([event('mine-old', start: at(-20, 9), end: at(-20, 10))],
          windowStart: at(-30, 0), windowEnd: at(30, 0));
      await seed([event('theirs-old', start: at(-20, 9), end: at(-20, 10))],
          windowStart: at(-30, 0), windowEnd: at(30, 0), account: 'acc2');

      await ds.pruneEventsEndingBefore(
          accountId: accountId, before: at(-14, 0));

      expect(
        await ds.getCachedEvents(
            accountId: 'acc2', start: at(-30, 0), end: at(30, 0)),
        hasLength(1),
      );
    });

    test('clearEventsForAccount empties one account', () async {
      await seed([event('e1', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0));
      await seed([event('e2', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0), account: 'acc2');

      await ds.clearEventsForAccount(accountId);

      expect(
        await ds.getCachedEvents(
            accountId: accountId, start: at(0, 0), end: at(1, 0)),
        isEmpty,
      );
      expect(
        await ds.getCachedEvents(
            accountId: 'acc2', start: at(0, 0), end: at(1, 0)),
        hasLength(1),
      );
    });

    test('cachedEventAccountIds lists each account once', () async {
      await seed([
        event('e1', start: at(0, 9), end: at(0, 10)),
        event('e2', start: at(1, 9), end: at(1, 10)),
      ], windowStart: at(0, 0), windowEnd: at(7, 0));
      await seed([event('e3', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(7, 0), account: 'acc2');

      final ids = await ds.cachedEventAccountIds();
      expect(ids.toSet(), {accountId, 'acc2'});
      expect(ids, hasLength(2));
    });
  });

  group('upsertEvent', () {
    test('replaces an existing row in place', () async {
      await seed([event('e1', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(1, 0));

      await ds.upsertEvent(
        accountId: accountId,
        event: event('e1', start: at(0, 9), end: at(0, 10))
            .copyWith(participation: MeetingParticipation.declined),
      );

      final read = await ds.getCachedEvents(
          accountId: accountId, start: at(0, 0), end: at(1, 0));
      expect(read, hasLength(1));
      expect(read.single.participation, MeetingParticipation.declined);
    });

    test('moving an event updates the indexed range so it changes weeks',
        () async {
      await seed([event('e1', start: at(0, 9), end: at(0, 10))],
          windowStart: at(0, 0), windowEnd: at(14, 0));

      await ds.upsertEvent(
        accountId: accountId,
        event: event('e1', start: at(8, 9), end: at(8, 10)),
      );

      expect(
        await ds.getCachedEvents(
            accountId: accountId, start: at(0, 0), end: at(7, 0)),
        isEmpty,
      );
      expect(
        await ds.getCachedEvents(
            accountId: accountId, start: at(7, 0), end: at(14, 0)),
        hasLength(1),
      );
    });
  });
}
