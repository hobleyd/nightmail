import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/gmail_contacts_datasource_impl.dart';

import 'gmail_contacts_datasource_impl_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GmailContactsDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GmailContactsDatasourceImpl.withDio(mockDio);
  });

  Response<Map<String, dynamic>> resp(List<Map<String, dynamic>> results) =>
      Response(
        data: {'results': results},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  Response<Map<String, dynamic>> emptyResp() => Response(
        data: <String, dynamic>{},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  // For searchContacts / otherContacts:search — each entry is {"person": {...}}
  Map<String, dynamic> person(String address, {String? name}) => {
        'person': {
          if (name != null) 'names': [
            {'displayName': name}
          ],
          'emailAddresses': [
            {'value': address}
          ],
        },
      };

  // For searchDirectoryPeople — each entry is a Person object directly, no wrapper
  Map<String, dynamic> directoryPerson(String address, {String? name}) => {
        if (name != null) 'names': [
          {'displayName': name}
        ],
        'emailAddresses': [
          {'value': address}
        ],
      };

  Response<Map<String, dynamic>> directoryResp(
          List<Map<String, dynamic>> people) =>
      Response(
        data: {'people': people},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  void stubPersonal(List<Map<String, dynamic>> results) {
    when(mockDio.get<Map<String, dynamic>>(
      argThat(contains('searchContacts')),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => resp(results));
  }

  void stubDirectory(List<Map<String, dynamic>> people) {
    when(mockDio.get<Map<String, dynamic>>(
      argThat(contains('searchDirectoryPeople')),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => directoryResp(people));
  }

  void stubOtherContacts(List<Map<String, dynamic>> results) {
    when(mockDio.get<Map<String, dynamic>>(
      argThat(contains('otherContacts')),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => resp(results));
  }

  group('searchContacts', () {
    test('returns personal contact results', () async {
      stubPersonal([person('alice@example.com', name: 'Alice')]);
      stubDirectory([]);
      stubOtherContacts([]);

      final results = await datasource.searchContacts('alice');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
      expect(results.first.name, 'Alice');
    });

    test('returns directory contact results', () async {
      stubPersonal([]);
      stubDirectory([directoryPerson('bob@corp.com', name: 'Bob')]);
      stubOtherContacts([]);

      final results = await datasource.searchContacts('bob');

      expect(results.length, 1);
      expect(results.first.address, 'bob@corp.com');
    });

    test('returns other contact results', () async {
      stubPersonal([]);
      stubDirectory([]);
      stubOtherContacts([person('carol@company.com', name: 'Carol')]);

      final results = await datasource.searchContacts('carol');

      expect(results.length, 1);
      expect(results.first.address, 'carol@company.com');
    });

    test('merges results from all three sources', () async {
      stubPersonal([person('alice@example.com', name: 'Alice')]);
      stubDirectory([directoryPerson('bob@corp.com', name: 'Bob')]);
      stubOtherContacts([person('carol@company.com', name: 'Carol')]);

      final results = await datasource.searchContacts('query');
      final addresses = results.map((r) => r.address).toSet();

      expect(addresses,
          containsAll(['alice@example.com', 'bob@corp.com', 'carol@company.com']));
    });

    test('deduplicates addresses across all sources', () async {
      stubPersonal([person('shared@corp.com', name: 'Alice')]);
      stubDirectory([
        directoryPerson('shared@corp.com', name: 'Alice Duplicate'),
        directoryPerson('unique@corp.com', name: 'Bob'),
      ]);
      stubOtherContacts([person('shared@corp.com', name: 'Alice Other')]);

      final results = await datasource.searchContacts('corp');
      final addresses = results.map((r) => r.address).toList();

      expect(addresses.where((a) => a == 'shared@corp.com').length, 1);
      expect(addresses, contains('unique@corp.com'));
    });

    test('handles missing name gracefully', () async {
      stubPersonal([person('noname@example.com')]);
      stubDirectory([]);
      stubOtherContacts([]);

      final results = await datasource.searchContacts('noname');

      expect(results.first.address, 'noname@example.com');
      expect(results.first.name, isNull);
    });

    test('returns empty list when API returns null data', () async {
      when(mockDio.get<Map<String, dynamic>>(
        argThat(contains('searchContacts')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => emptyResp());
      when(mockDio.get<Map<String, dynamic>>(
        argThat(contains('searchDirectoryPeople')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => emptyResp());
      when(mockDio.get<Map<String, dynamic>>(
        argThat(contains('otherContacts')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => emptyResp());

      final results = await datasource.searchContacts('query');
      expect(results, isEmpty);
    });

    test('returns partial results when directory endpoint fails', () async {
      stubPersonal([person('alice@example.com', name: 'Alice')]);
      stubOtherContacts([]);
      when(mockDio.get<Map<String, dynamic>>(
        argThat(contains('searchDirectoryPeople')),
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: ''),
        ),
      ));

      final results = await datasource.searchContacts('alice');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
    });

    test('returns empty list when all endpoints fail', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(requestOptions: RequestOptions(path: '')));

      final results = await datasource.searchContacts('query');
      expect(results, isEmpty);
    });
  });
}
