// What the cache sync service is responsible for: the shape of the window it
// keeps warm (today through four weeks), expiring what finished more than a
// fortnight ago, and not blanking the cache when a provider is unreachable.
//
// The calendar datasource is mocked, but the cache is the real AppDatabase on an
// in-memory NativeDatabase — the window arithmetic only means anything against
// the SQL that stores it.

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/calendar_local_datasource.dart';
import 'package:nightmail/data/datasources/local/calendar_local_datasource_impl.dart';
import 'package:nightmail/data/datasources/local/pending_calendar_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';
import 'package:nightmail/infrastructure/calendar/calendar_cache_sync_service.dart';
import 'package:nightmail/infrastructure/sync/calendar_outbox_drain_service.dart';

import 'calendar_cache_sync_service_test.mocks.dart';

class _PlaintextEncryption extends CacheEncryptionService {
  _PlaintextEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async => plaintext;

  @override
  Future<String> decrypt(String stored) async => stored;
}

@GenerateMocks([
  AccountManager,
  CalendarRemoteDatasource,
  CalendarOutboxDrainService,
])
void main() {
  const account = GmailAccount(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'me@example.com',
  );

  late AppDatabase db;
  late CalendarLocalDatasource cache;
  late MockAccountManager accountManager;
  late MockCalendarRemoteDatasource datasource;
  late MockCalendarOutboxDrainService drain;
  late CalendarCacheSyncService service;

  CalendarEventModel event(String id, {required DateTime start}) =>
      CalendarEventModel(
        id: id,
        subject: 'Event $id',
        start: start.toUtc(),
        end: start.toUtc().add(const Duration(minutes: 30)),
        isAllDay: false,
      );

  void stubEvents(List<CalendarEventModel> events) {
    when(datasource.getCalendarEvents(
      startDateTime: anyNamed('startDateTime'),
      endDateTime: anyNamed('endDateTime'),
    )).thenAnswer((_) async => events);
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cache = CalendarLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
    );
    accountManager = MockAccountManager();
    datasource = MockCalendarRemoteDatasource();
    drain = MockCalendarOutboxDrainService();

    when(accountManager.accounts).thenReturn([account]);
    when(accountManager.activeAccount).thenReturn(account);
    when(accountManager.calendarDatasource).thenReturn(datasource);
    when(drain.drainAll()).thenAnswer((_) async {});

    service = CalendarCacheSyncService(
      accountManager: accountManager,
      cache: cache,
      pendingOperations: db,
      outboxDrainService: drain,
    );
  });

  tearDown(() => db.close());

  group('currentWindow', () {
    test('starts at local midnight today and runs four weeks out', () {
      final (start, end) = CalendarCacheSyncService.currentWindow();
      final now = DateTime.now();
      final expectedStart = DateTime(now.year, now.month, now.day).toUtc();

      // Local midnight, not "now": a meeting that started an hour ago is still
      // one of today's, so the whole of today has to be inside the window.
      expect(start, expectedStart);
      expect(end.difference(start), const Duration(days: 28));
      expect(CalendarCacheSyncService.lookahead, const Duration(days: 28));
      expect(CalendarCacheSyncService.retention, const Duration(days: 14));
    });
  });

  group('syncAccount', () {
    test('fetches the window and caches what comes back', () async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      stubEvents([event('e1', start: tomorrow)]);

      await service.syncAccount(account.id);

      final (start, end) = CalendarCacheSyncService.currentWindow();
      final captured = verify(datasource.getCalendarEvents(
        startDateTime: captureAnyNamed('startDateTime'),
        endDateTime: captureAnyNamed('endDateTime'),
      )).captured;
      expect(captured[0], start);
      expect(captured[1], end);

      final cached =
          await cache.getCachedEvents(accountId: account.id, start: start, end: end);
      expect(cached.map((e) => e.id), ['e1']);
    });

    test('drops meetings that finished more than a fortnight ago', () async {
      final now = DateTime.now().toUtc();
      // Seeded straight into the cache, standing in for earlier syncs.
      await cache.cacheEvents(
        accountId: account.id,
        windowStart: now.subtract(const Duration(days: 60)),
        windowEnd: now.add(const Duration(days: 60)),
        events: [
          event('long-past', start: now.subtract(const Duration(days: 30))),
          event('just-inside', start: now.subtract(const Duration(days: 10))),
          event('upcoming', start: now.add(const Duration(days: 3))),
        ],
      );
      stubEvents([]);

      await service.syncAccount(account.id);

      final remaining = await cache.getCachedEvents(
        accountId: account.id,
        start: now.subtract(const Duration(days: 60)),
        end: now.add(const Duration(days: 60)),
      );
      // 'upcoming' was inside the fetched window, which came back empty, so it
      // is correctly gone; 'just-inside' is older than the window but younger
      // than the retention cut-off, so it stays.
      expect(remaining.map((e) => e.id), ['just-inside']);
    });

    test('a failed fetch leaves the previous cache in place', () async {
      final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
      final (start, end) = CalendarCacheSyncService.currentWindow();
      await cache.cacheEvents(
        accountId: account.id,
        windowStart: start,
        windowEnd: end,
        events: [event('already-cached', start: tomorrow)],
      );
      when(datasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenThrow(Exception('offline'));

      // Never throws — a failing account must not take the pass down with it.
      await service.syncAccount(account.id);

      final cached = await cache.getCachedEvents(
          accountId: account.id, start: start, end: end);
      expect(cached.map((e) => e.id), ['already-cached']);
    });

    test('prunes even when the account has no calendar at all', () async {
      final now = DateTime.now().toUtc();
      await cache.cacheEvents(
        accountId: account.id,
        windowStart: now.subtract(const Duration(days: 60)),
        windowEnd: now,
        events: [event('long-past', start: now.subtract(const Duration(days: 30)))],
      );
      when(accountManager.calendarDatasource).thenReturn(null);

      await service.syncAccount(account.id);

      final remaining = await cache.getCachedEvents(
        accountId: account.id,
        start: now.subtract(const Duration(days: 60)),
        end: now,
      );
      expect(remaining, isEmpty);
    });

    test('overlapping calls collapse into a single fetch', () async {
      stubEvents([]);

      await Future.wait([
        service.syncAccount(account.id),
        service.syncAccount(account.id),
      ]);

      verify(datasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).called(1);
    });
  });

  group('syncAll', () {
    test('pushes queued mutations before re-reading the calendars', () async {
      stubEvents([]);

      await service.syncAll();

      // Ordering matters: a fetch that overtook the drain would write server
      // state predating the optimistic change back over the cache.
      verifyInOrder([
        drain.drainAll(),
        datasource.getCalendarEvents(
          startDateTime: anyNamed('startDateTime'),
          endDateTime: anyNamed('endDateTime'),
        ),
      ]);
    });

    test('forgets meetings belonging to an account that has been removed',
        () async {
      final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
      final (start, end) = CalendarCacheSyncService.currentWindow();
      await cache.cacheEvents(
        accountId: 'gone-acct',
        windowStart: start,
        windowEnd: end,
        events: [event('orphan', start: tomorrow)],
      );
      stubEvents([]);

      await service.syncAll();

      expect(
        await cache.getCachedEvents(
            accountId: 'gone-acct', start: start, end: end),
        isEmpty,
      );
    });
  });

  group('clearAccount', () {
    test('drops both the cached meetings and the queued mutations', () async {
      final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1));
      final (start, end) = CalendarCacheSyncService.currentWindow();
      await cache.cacheEvents(
        accountId: account.id,
        windowStart: start,
        windowEnd: end,
        events: [event('e1', start: tomorrow)],
      );
      await db.enqueueCalendarOperation(
        accountId: account.id,
        targetId: 'e1',
        opType: PendingCalendarOperationType.declineEvent,
        payload: '{}',
      );

      await service.clearAccount(account.id);

      expect(
        await cache.getCachedEvents(
            accountId: account.id, start: start, end: end),
        isEmpty,
      );
      // Replaying an RSVP against a mailbox the user just disconnected would be
      // wrong, so the queue goes with the cache.
      expect(await db.getPendingCalendarOperations(account.id), isEmpty);
    });
  });
}
