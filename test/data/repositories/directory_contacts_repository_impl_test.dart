import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/gmail_contacts_datasource_impl.dart';
import 'package:nightmail/data/repositories/directory_contacts_repository_impl.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

import 'directory_contacts_repository_impl_test.mocks.dart';

@GenerateMocks([AccountManager, Dio])
void main() {
  late MockAccountManager mockAccountManager;
  late DirectoryContactsRepositoryImpl repository;

  setUp(() {
    mockAccountManager = MockAccountManager();
    repository =
        DirectoryContactsRepositoryImpl(accountManager: mockAccountManager);
  });

  group('DirectoryContactsRepositoryImpl', () {
    test('returns empty list when contactsDatasourceForAccount returns null',
        () async {
      when(mockAccountManager.contactsDatasourceForAccount(any))
          .thenReturn(null);

      final results =
          await repository.search('alice', accountId: 'acct-1');
      expect(results, isEmpty);
    });

    test('delegates to contactsDatasourceForAccount and returns its results',
        () async {
      final mockDio = MockDio();

      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            data: {
              'results': [
                {
                  'person': {
                    'names': [
                      {'displayName': 'Alice'}
                    ],
                    'emailAddresses': [
                      {'value': 'alice@corp.com'}
                    ],
                  }
                }
              ]
            },
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ));

      final datasource = GmailContactsDatasourceImpl.withDio(mockDio);
      when(mockAccountManager.contactsDatasourceForAccount(any))
          .thenReturn(datasource);

      final results = await repository.search('alice', accountId: 'acct-1');

      expect(results, hasLength(greaterThan(0)));
      expect(results.any((r) => r.address == 'alice@corp.com'), isTrue);
    });

    test('returns empty list when datasource returns no results', () async {
      final mockDio = MockDio();
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            data: {'results': <dynamic>[]},
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ));

      final datasource = GmailContactsDatasourceImpl.withDio(mockDio);
      when(mockAccountManager.contactsDatasourceForAccount(any))
          .thenReturn(datasource);

      final results = await repository.search('nobody', accountId: 'acct-1');
      expect(results, isEmpty);
    });
  });
}
