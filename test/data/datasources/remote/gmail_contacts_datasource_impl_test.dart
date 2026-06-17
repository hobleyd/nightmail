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

  Response<Map<String, dynamic>> _resp(List<Map<String, dynamic>> results) =>
      Response(
        data: {'results': results},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  Response<Map<String, dynamic>> _emptyResp() => Response(
        data: <String, dynamic>{},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  Map<String, dynamic> _person(String address, {String? name}) => {
        'person': {
          if (name != null) 'names': [
            {'displayName': name}
          ],
          'emailAddresses': [
            {'value': address}
          ],
        },
      };

  void stubPersonal(List<Map<String, dynamic>> results) {
    when(mockDio.get<Map<String, dynamic>>(
      argThat(contains('searchContacts')),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => _resp(results));
  }

  void stubDirectory(List<Map<String, dynamic>> results) {
    when(mockDio.get<Map<String, dynamic>>(
      argThat(contains('searchDirectoryPeople')),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => _resp(results));
  }

  group('searchContacts', () {
    test('returns personal contact results', () async {
      stubPersonal([_person('alice@example.com', name: 'Alice')]);
      stubDirectory([]);

      final results = await datasource.searchContacts('alice');

      expect(results.length, 1);
      expect(results.first.address, 'alice@example.com');
      expect(results.first.name, 'Alice');
    });

    test('returns directory contact results', () async {
      stubPersonal([]);
      stubDirectory([_person('bob@corp.com', name: 'Bob')]);

      final results = await datasource.searchContacts('bob');

      expect(results.length, 1);
      expect(results.first.address, 'bob@corp.com');
    });

    test('merges personal and directory results', () async {
      stubPersonal([_person('alice@example.com', name: 'Alice')]);
      stubDirectory([_person('bob@corp.com', name: 'Bob')]);

      final results = await datasource.searchContacts('query');
      final addresses = results.map((r) => r.address).toSet();

      expect(addresses, containsAll(['alice@example.com', 'bob@corp.com']));
    });

    test('deduplicates addresses across personal and directory', () async {
      stubPersonal([_person('shared@corp.com', name: 'Alice')]);
      stubDirectory([
        _person('shared@corp.com', name: 'Alice Duplicate'),
        _person('unique@corp.com', name: 'Bob'),
      ]);

      final results = await datasource.searchContacts('corp');
      final addresses = results.map((r) => r.address).toList();

      expect(addresses.where((a) => a == 'shared@corp.com').length, 1);
      expect(addresses, contains('unique@corp.com'));
    });

    test('handles missing name gracefully', () async {
      stubPersonal([_person('noname@example.com')]);
      stubDirectory([]);

      final results = await datasource.searchContacts('noname');

      expect(results.first.address, 'noname@example.com');
      expect(results.first.name, isNull);
    });

    test('returns empty list when API returns null data', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => _emptyResp());

      final results = await datasource.searchContacts('query');
      expect(results, isEmpty);
    });

    test('returns partial results when directory endpoint fails', () async {
      stubPersonal([_person('alice@example.com', name: 'Alice')]);
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

    test('returns empty list when both endpoints fail', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(requestOptions: RequestOptions(path: '')));

      final results = await datasource.searchContacts('query');
      expect(results, isEmpty);
    });
  });
}
