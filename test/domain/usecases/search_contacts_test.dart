import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/domain/entities/cached_contact.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/domain/repositories/directory_contacts_repository.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';

import 'search_contacts_test.mocks.dart';

@GenerateMocks([
  SenderRepository,
  ContactCacheRepository,
  SystemContactsRepository,
  DirectoryContactsRepository,
])
void main() {
  late SearchContacts useCase;
  late MockSenderRepository mockSenders;
  late MockContactCacheRepository mockCache;
  late MockSystemContactsRepository mockSystemContacts;
  late MockDirectoryContactsRepository mockDirectoryContacts;

  /// Stubs every source to return nothing and the cache to be populated, so
  /// each test only has to set up the source it is actually about.
  void stubEmpty({bool synced = true}) {
    when(mockSenders.searchSendersForAccount(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => []);
    when(mockCache.search(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => []);
    when(mockCache.hasSyncedAccount(any)).thenAnswer((_) async => synced);
    when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
    when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')))
        .thenAnswer((_) async => []);
  }

  void stubSenders(List<KnownSenderEntry> entries) {
    when(mockSenders.searchSendersForAccount(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => entries);
  }

  void stubCache(List<CachedContact> contacts) {
    when(mockCache.search(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => contacts);
  }

  setUp(() {
    mockSenders = MockSenderRepository();
    mockCache = MockContactCacheRepository();
    mockSystemContacts = MockSystemContactsRepository();
    mockDirectoryContacts = MockDirectoryContactsRepository();
    useCase = SearchContacts(
      senderRepository: mockSenders,
      contactCacheRepository: mockCache,
      systemContactsRepository: mockSystemContacts,
      directoryContactsRepository: mockDirectoryContacts,
    );
  });

  group('SearchContacts', () {
    test('returns empty list without hitting repositories when query is blank',
        () async {
      stubEmpty();

      expect(await useCase.call(query: '', accountId: 'acc1'), isEmpty);
      expect(await useCase.call(query: '   ', accountId: 'acc1'), isEmpty);

      verifyNever(mockSenders.searchSendersForAccount(
        accountId: anyNamed('accountId'),
        query: anyNamed('query'),
        limit: anyNamed('limit'),
      ));
      verifyNever(mockCache.search(
        accountId: anyNamed('accountId'),
        query: anyNamed('query'),
        limit: anyNamed('limit'),
      ));
      verifyNever(mockSystemContacts.search(any));
      verifyNever(
          mockDirectoryContacts.search(any, accountId: anyNamed('accountId')));
    });

    test('returns known senders that match query', () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
      ]);

      final results = await useCase.call(query: 'alice', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
      expect(results.first.name, 'Alice');
    });

    test('lower-cases and trims the query before passing it to the sources',
        () async {
      stubEmpty();

      await useCase.call(query: '  Alice  ', accountId: 'acc1');

      verify(mockSenders.searchSendersForAccount(
        accountId: 'acc1',
        query: 'alice',
        limit: anyNamed('limit'),
      )).called(1);
      verify(mockCache.search(
        accountId: 'acc1',
        query: 'alice',
        limit: anyNamed('limit'),
      )).called(1);
    });

    test('merges cached directory contacts with known senders', () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'alice@corp.com', name: 'Alice'),
      ]);
      stubCache([
        const CachedContact(
          address: 'bob@corp.com',
          name: 'Bob',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(query: 'corp', accountId: 'acc1');

      expect(results.map((r) => r.address),
          containsAll(['alice@corp.com', 'bob@corp.com']));
    });

    test('places known senders before directory results of the same rank',
        () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'zoe@corp.com', name: 'Zoe'),
      ]);
      stubCache([
        const CachedContact(
          address: 'adam@corp.com',
          name: 'Adam',
          source: ContactSource.directory,
        ),
      ]);

      // Both only match mid-string, so nothing outranks the source ordering —
      // the sender wins despite sorting last alphabetically.
      final results = await useCase.call(query: 'corp', accountId: 'acc1');

      expect(results.first.address, 'zoe@corp.com');
      expect(results.last.address, 'adam@corp.com');
    });

    test('ranks a prefix match above a better-sourced mid-string match',
        () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'x@corp.com', name: 'Jo Ashby'),
      ]);
      stubCache([
        const CachedContact(
          address: 'ash@corp.com',
          name: 'Ashley Brown',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(query: 'ash', accountId: 'acc1');

      expect(results.first.address, 'ash@corp.com');
    });

    test('treats a word inside the name as a prefix match', () async {
      stubEmpty();
      stubCache([
        const CachedContact(
          address: 'a@corp.com',
          name: 'Zara Hobley',
          source: ContactSource.directory,
        ),
        const CachedContact(
          address: 'b@corp.com',
          name: 'Nathob Kim',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(query: 'hob', accountId: 'acc1');

      expect(results.first.address, 'a@corp.com');
    });

    test('puts contacts on the account domain first', () async {
      stubEmpty();
      stubCache([
        const CachedContact(
          address: 'sam@external.com',
          name: 'Sam Ext',
          source: ContactSource.directory,
        ),
        const CachedContact(
          address: 'sam@corp.com',
          name: 'Sam Int',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(
        query: 'sam',
        accountId: 'acc1',
        accountDomain: 'corp.com',
      );

      expect(results.first.address, 'sam@corp.com');
    });

    test('deduplicates an address shared between senders and the cache',
        () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'alice@corp.com', name: 'Alice'),
      ]);
      stubCache([
        const CachedContact(
          address: 'alice@corp.com',
          name: 'Alice (dir)',
          source: ContactSource.directory,
        ),
        const CachedContact(
          address: 'carol@corp.com',
          name: 'Carol',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(query: 'corp', accountId: 'acc1');
      final addresses = results.map((r) => r.address).toList();

      expect(addresses.where((a) => a == 'alice@corp.com').length, 1);
      expect(addresses, contains('carol@corp.com'));
      // The known-sender copy is the better-ranked source, so its name wins.
      expect(
        results.firstWhere((r) => r.address == 'alice@corp.com').name,
        'Alice',
      );
    });

    test('cache error does not prevent sender results from returning',
        () async {
      stubEmpty();
      stubSenders([
        KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
      ]);
      when(mockCache.search(
        accountId: anyNamed('accountId'),
        query: anyNamed('query'),
        limit: anyNamed('limit'),
      )).thenAnswer((_) => Future.error(Exception('db')));

      final results = await useCase.call(query: 'alice', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
    });

    test('sender error does not prevent cached results from returning',
        () async {
      stubEmpty();
      when(mockSenders.searchSendersForAccount(
        accountId: anyNamed('accountId'),
        query: anyNamed('query'),
        limit: anyNamed('limit'),
      )).thenThrow(Exception('db'));
      stubCache([
        const CachedContact(
          address: 'bob@corp.com',
          name: '',
          source: ContactSource.directory,
        ),
      ]);

      final results = await useCase.call(query: 'bob', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'bob@corp.com');
      expect(results.first.name, isNull);
    });

    test('does not hit live sources once the account has been synced',
        () async {
      stubEmpty();

      await useCase.call(query: 'alice', accountId: 'acc1');

      verifyNever(mockSystemContacts.search(any));
      verifyNever(
          mockDirectoryContacts.search(any, accountId: anyNamed('accountId')));
    });

    test('falls back to live sources when the account has never been synced',
        () async {
      stubEmpty(synced: false);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')))
          .thenAnswer((_) async => [
                ContactSuggestion(address: 'live@corp.com', name: 'Live'),
              ]);

      final results = await useCase.call(query: 'live', accountId: 'acc1');

      expect(results.single.address, 'live@corp.com');
      verify(mockSystemContacts.search('live')).called(1);
    });

    test('live fallback error still returns local results', () async {
      stubEmpty(synced: false);
      stubSenders([
        KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
      ]);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')))
          .thenAnswer((_) => Future.error(Exception('network')));

      final results = await useCase.call(query: 'alice', accountId: 'acc1');

      expect(results.single.address, 'alice@example.com');
    });

    test('caps total results at 8', () async {
      stubEmpty();
      stubSenders(List.generate(
        5,
        (i) => KnownSenderEntry(
            address: 'sender$i@example.com', name: 'Sender $i'),
      ));
      stubCache(List.generate(
        6,
        (i) => CachedContact(
          address: 'dir$i@example.com',
          name: '',
          source: ContactSource.directory,
        ),
      ));

      final results = await useCase.call(query: 'example', accountId: 'acc1');

      expect(results.length, 8);
    });
  });
}
