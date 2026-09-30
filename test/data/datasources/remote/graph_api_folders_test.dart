import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_folders_test.mocks.dart';

Map<String, dynamic> _folderJson(String id, {String? parentFolderId}) => {
      'id': id,
      'displayName': 'Folder $id',
      'totalItemCount': 0,
      'unreadItemCount': 0,
      'parentFolderId': parentFolderId,
      'isHidden': false,
      'childFolderCount': 0,
    };

/// A page body, optionally carrying the `@odata.nextLink` Graph hands back
/// when more remain. The link has to be a real Graph host: `graphNextLink`
/// runs it through `isGraphUrl` before following it, because the next request
/// carries the account's access token.
Response<String> _page(List<String> ids, {String? nextLink}) => Response(
      data: jsonEncode({
        'value': [for (final id in ids) _folderJson(id)],
        '@odata.nextLink': ?nextLink,
      }),
      statusCode: 200,
      requestOptions: RequestOptions(path: ''),
    );

const _next = 'https://graph.microsoft.com/v1.0/me/mailFolders?\$skiptoken=x';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  // Regression: both folder listings asked for `$top: 100` and then read
  // `value` off the first response alone. Graph hands the rest back behind
  // `@odata.nextLink`, so every folder past the cap was dropped — no error and
  // no empty state, the folders simply were not in the panel.
  group('folder listings follow @odata.nextLink', () {
    test('getMailFolders returns the folders on every page', () async {
      when(mockDio.get<String>(
        '/me/mailFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['a', 'b'], nextLink: _next));
      when(mockDio.get<String>(
        _next,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['c']));

      final folders = await datasource.getMailFolders();

      expect(folders.map((f) => f.id), ['a', 'b', 'c']);
    });

    test('getChildFolders returns the children on every page', () async {
      when(mockDio.get<String>(
        '/me/mailFolders/parent-1/childFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['a'], nextLink: _next));
      when(mockDio.get<String>(
        _next,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['b', 'c']));

      final folders = await datasource.getChildFolders('parent-1');

      expect(folders.map((f) => f.id), ['a', 'b', 'c']);
    });

    // The paging state is baked into the nextLink URL, so re-applying the
    // original query parameters to it is what makes Graph 400 the follow-up.
    test('the follow-up request carries no query parameters of its own',
        () async {
      when(mockDio.get<String>(
        '/me/mailFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['a'], nextLink: _next));

      Map<String, dynamic>? followUpParams;
      var followUpCalls = 0;
      when(mockDio.get<String>(
        _next,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        followUpCalls++;
        followUpParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>?;
        return _page(['b']);
      });

      await datasource.getMailFolders();

      expect(followUpCalls, 1);
      expect(followUpParams, isNull);
    });

    test('a single page is returned without a follow-up request', () async {
      when(mockDio.get<String>(
        '/me/mailFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _page(['a', 'b']));

      final folders = await datasource.getMailFolders();

      expect(folders.map((f) => f.id), ['a', 'b']);
      verify(mockDio.get<String>(
        '/me/mailFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).called(1);
      verifyNoMoreInteractions(mockDio);
    });

    test('the first request still asks for the folder columns', () async {
      Map<String, dynamic>? params;
      when(mockDio.get<String>(
        '/me/mailFolders',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        params =
            invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
        return _page(['a']);
      });

      await datasource.getMailFolders();

      expect(params?[r'$select'], contains('displayName'));
      expect(params?[r'$select'], contains('childFolderCount'));
      expect(params?[r'$top'], 100);
    });
  });
}
