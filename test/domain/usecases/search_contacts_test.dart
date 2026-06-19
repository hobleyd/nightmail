import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/directory_contacts_repository.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';

import 'search_contacts_test.mocks.dart';

@GenerateMocks([SenderRepository, SystemContactsRepository, DirectoryContactsRepository])
void main() {
  late SearchContacts useCase;
  late MockSenderRepository mockSenders;
  late MockSystemContactsRepository mockSystemContacts;
  late MockDirectoryContactsRepository mockDirectoryContacts;

  setUp(() {
    mockSenders = MockSenderRepository();
    mockSystemContacts = MockSystemContactsRepository();
    mockDirectoryContacts = MockDirectoryContactsRepository();
    useCase = SearchContacts(
      senderRepository: mockSenders,
      systemContactsRepository: mockSystemContacts,
      directoryContactsRepository: mockDirectoryContacts,
    );
  });

  void stubEmpty() {
    when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async => []);
    when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
    when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => []);
  }

  group('SearchContacts', () {
    test('returns empty list without hitting repositories when query is blank',
        () async {
      await useCase.call(query: '', accountId: 'acc1');
      await useCase.call(query: '   ', accountId: 'acc1');

      verifyNever(mockSenders.getSendersForAccount(any));
      verifyNever(mockSystemContacts.search(any));
      verifyNever(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')));
    });

    test('returns known senders that match query', () async {
      when(mockSenders.getSendersForAccount('acc1')).thenAnswer((_) async => [
            KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
            KnownSenderEntry(address: 'bob@example.com', name: 'Bob'),
          ]);
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => []);

      final results = await useCase.call(query: 'alice', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
      expect(results.first.name, 'Alice');
    });

    test('matches sender by name as well as address', () async {
      when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async => [
            KnownSenderEntry(address: 'x@example.com', name: 'Alice Smith'),
          ]);
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => []);

      final results = await useCase.call(query: 'smith', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'x@example.com');
    });

    test('places known senders before directory results', () async {
      when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async => [
            KnownSenderEntry(address: 'alice@corp.com', name: 'Alice'),
          ]);
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => [
            ContactSuggestion(address: 'bob@corp.com', name: 'Bob'),
          ]);

      final results = await useCase.call(query: 'corp', accountId: 'acc1');

      expect(results.first.address, 'alice@corp.com');
      expect(results.last.address, 'bob@corp.com');
    });

    test('deduplicates address shared between sender cache and directory',
        () async {
      when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async => [
            KnownSenderEntry(address: 'alice@corp.com', name: 'Alice'),
          ]);
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => [
            ContactSuggestion(address: 'alice@corp.com', name: 'Alice (dir)'),
            ContactSuggestion(address: 'carol@corp.com', name: 'Carol'),
          ]);

      final results = await useCase.call(query: 'corp', accountId: 'acc1');
      final addresses = results.map((r) => r.address).toList();

      expect(addresses.where((a) => a == 'alice@corp.com').length, 1);
      expect(addresses, contains('carol@corp.com'));
    });

    test('directory error does not prevent sender results from returning',
        () async {
      when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async => [
            KnownSenderEntry(address: 'alice@example.com', name: 'Alice'),
          ]);
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      // Use thenAnswer with Future.error so the rejection propagates asynchronously
      // through catchError rather than throwing synchronously before the chain forms.
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId')))
          .thenAnswer((_) => Future.error(Exception('network')));

      final results = await useCase.call(query: 'alice', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
    });

    test('sender cache error does not prevent directory results from returning',
        () async {
      when(mockSenders.getSendersForAccount(any)).thenThrow(Exception('db'));
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async => [
            ContactSuggestion(address: 'bob@corp.com'),
          ]);

      final results = await useCase.call(query: 'bob', accountId: 'acc1');

      expect(results.length, 1);
      expect(results.first.address, 'bob@corp.com');
    });

    test('caps total results at 8', () async {
      when(mockSenders.getSendersForAccount(any)).thenAnswer((_) async =>
          List.generate(
              5,
              (i) => KnownSenderEntry(
                  address: 'sender$i@example.com', name: 'Sender $i')));
      when(mockSystemContacts.search(any)).thenAnswer((_) async => []);
      when(mockDirectoryContacts.search(any, accountId: anyNamed('accountId'))).thenAnswer((_) async =>
          List.generate(
              6,
              (i) => ContactSuggestion(address: 'dir$i@example.com')));

      final results = await useCase.call(query: 'example', accountId: 'acc1');

      expect(results.length, 8);
    });
  });
}
