import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/domain/entities/cached_contact.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';

import 'search_contacts_test.mocks.dart';

/// What `SearchContacts` writes to the diagnostic log, as distinct from what
/// it answers — see "Self-reporting" in `lib/infrastructure/contacts/CLAUDE.md`.
void main() {
  late SearchContacts useCase;
  late MockSenderRepository mockSenders;
  late MockContactCacheRepository mockCache;
  late MockSystemContactsRepository mockSystemContacts;
  late MockDirectoryContactsRepository mockDirectoryContacts;
  late List<String> lines;
  late DebugPrintCallback previousDebugPrint;

  void stub({
    List<KnownSenderEntry> senders = const [],
    List<CachedContact> cached = const [],
    bool synced = true,
  }) {
    when(mockSenders.searchSendersForAccount(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => senders);
    when(mockCache.search(
      accountId: anyNamed('accountId'),
      query: anyNamed('query'),
      limit: anyNamed('limit'),
    )).thenAnswer((_) async => cached);
    when(mockCache.hasSyncedAccount(any)).thenAnswer((_) async => synced);
    when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
    when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')))
        .thenAnswer((_) async => []);
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
    lines = [];
    previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      lines.add(message ?? '');
    };
  });

  tearDown(() {
    debugPrint = previousDebugPrint;
  });

  test('an empty answer is logged with where each source stood, not the query',
      () async {
    stub();

    final results = await useCase.call(query: 'zed', accountId: 'acc1');

    expect(results, isEmpty);
    expect(lines, hasLength(1));
    expect(
      lines.single,
      startsWith('[NightMail] contact search: no match for a 3-char query '
          '(account acc1; senders 0, cached 0, cache synced, live 0; '),
    );
    expect(lines.single, endsWith(' ms)'));
    expect(lines.single, isNot(contains('zed')));
  });

  test('an unsynced cache is named, with the live fallback counted', () async {
    stub(synced: false);

    await useCase.call(query: 'zed', accountId: 'acc1');

    expect(lines.single, contains('cache unsynced, live 0;'));
    verify(mockDirectoryContacts.search('zed', accountId: 'acc1')).called(1);
  });

  test('a match logs nothing', () async {
    stub(senders: [
      KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
    ]);

    final results = await useCase.call(query: 'ali', accountId: 'acc1');

    expect(results, hasLength(1));
    expect(lines, isEmpty);
  });
}
