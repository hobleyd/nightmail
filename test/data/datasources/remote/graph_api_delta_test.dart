import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_delta_test.mocks.dart';

Map<String, dynamic> _emailJson(String id, {bool isRead = false}) => {
      'id': id,
      'subject': 'Test $id',
      'from': {
        'emailAddress': {'address': 'sender@example.com', 'name': 'Sender'}
      },
      'toRecipients': <dynamic>[],
      'ccRecipients': <dynamic>[],
      'bodyPreview': 'Preview',
      'isRead': isRead,
      'receivedDateTime': '2026-06-01T10:00:00Z',
      'sentDateTime': '2026-06-01T09:59:00Z',
      'importance': 'normal',
      'conversationId': 'conv-1',
      'hasAttachments': false,
      'parentFolderId': 'inbox',
    };

/// Delta pages are requested with `ResponseType.plain` so the parse can run on a
/// background isolate, so the stub answers with the page still encoded.
Response<String> _resp(
  Map<String, dynamic> data, {
  String path = '/me/mailFolders/inbox/messages/delta',
}) =>
    Response(
      data: jsonEncode(data),
      statusCode: 200,
      requestOptions: RequestOptions(path: path),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  group('GraphApiDatasourceImpl.syncMailDelta — initial sync', () {
    test('calls /me/mailFolders/{folderId}/messages/delta', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      await datasource.syncMailDelta('inbox');

      final captured = verify(mockDio.get<String>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;

      expect(captured.first, '/me/mailFolders/inbox/messages/delta');
    });

    test('sends \$select and \$top but never a date \$filter', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      await datasource.syncMailDelta('inbox');

      final params = verify(mockDio.get<String>(
        any,
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.first as Map<String, dynamic>;

      expect(params.containsKey(r'$select'), isTrue);
      expect(params[r'$top'], 50);
      // A receivedDateTime cutoff would be frozen into the delta link Graph
      // hands back, hiding every later change to an older message for ever.
      expect(params.containsKey(r'$filter'), isFalse);
    });

    test('returns upserted messages and empty removedIds', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_emailJson('msg-1'), _emailJson('msg-2', isRead: true)],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      final result = await datasource.syncMailDelta('inbox');

      expect(result.upserted.length, 2);
      expect(result.upserted.map((e) => e.id), containsAll(['msg-1', 'msg-2']));
      expect(result.removedIds, isEmpty);
    });

    test('separates @removed items into removedIds', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [
              _emailJson('msg-kept'),
              {'id': 'msg-deleted', '@removed': <String, dynamic>{'reason': 'deleted'}},
            ],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      final result = await datasource.syncMailDelta('inbox');

      expect(result.upserted.length, 1);
      expect(result.upserted.first.id, 'msg-kept');
      expect(result.removedIds, ['msg-deleted']);
    });

    test('returns the @odata.deltaLink value', () async {
      const expected = 'https://graph.microsoft.com/v1.0/delta-token-abc';
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink': expected,
          }));

      final result = await datasource.syncMailDelta('inbox');

      expect(result.deltaLink, expected);
    });

    test('follows @odata.nextLink pages and accumulates results', () async {
      const nextLink = 'https://graph.microsoft.com/v1.0/next-page';
      const deltaLink = 'https://graph.microsoft.com/v1.0/delta-final';

      int calls = 0;
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        calls++;
        if (calls == 1) {
          return _resp({
            'value': [_emailJson('page1-msg')],
            '@odata.nextLink': nextLink,
          });
        }
        return _resp({
          'value': [_emailJson('page2-msg')],
          '@odata.deltaLink': deltaLink,
        }, path: nextLink);
      });

      final result = await datasource.syncMailDelta('inbox');

      expect(calls, 2);
      expect(result.upserted.length, 2);
      expect(result.upserted.map((e) => e.id),
          containsAll(['page1-msg', 'page2-msg']));
      expect(result.deltaLink, deltaLink);
    });

    test('hasChanges is false when value list is empty', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      final result = await datasource.syncMailDelta('inbox');

      expect(result.hasChanges, isFalse);
    });

    test('hasChanges is true when messages are returned', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_emailJson('new-msg')],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-1',
          }));

      final result = await datasource.syncMailDelta('inbox');

      expect(result.hasChanges, isTrue);
    });
  });

  group('GraphApiDatasourceImpl.syncMailDelta — incremental sync', () {
    test('uses the saved delta link URL directly without path construction',
        () async {
      const savedLink =
          'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?\$deltatoken=xyz';

      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink':
                'https://graph.microsoft.com/v1.0/delta-token-new',
          }, path: savedLink));

      await datasource.syncMailDelta('inbox', deltaLink: savedLink);

      final url = verify(mockDio.get<String>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.first as String;

      expect(url, savedLink);
    });

    test(r'does not include $filter when using saved delta link', () async {
      const savedLink = 'https://graph.microsoft.com/v1.0/delta-token';

      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': <dynamic>[],
            '@odata.deltaLink': 'https://graph.microsoft.com/v1.0/delta-new',
          }, path: savedLink));

      await datasource.syncMailDelta('inbox', deltaLink: savedLink);

      // Verify there were no query parameters — the delta link is a full URL
      // that already encodes all params.
      final qp = verify(mockDio.get<String>(
        any,
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.first;

      expect(qp, isNull);
    });

    test('saves new delta link returned from incremental sync', () async {
      const newDelta = 'https://graph.microsoft.com/v1.0/delta-updated';
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_emailJson('incoming')],
            '@odata.deltaLink': newDelta,
          }));

      final result = await datasource.syncMailDelta('inbox',
          deltaLink: 'https://graph.microsoft.com/v1.0/old-token');

      expect(result.deltaLink, newDelta);
    });
  });

  group('GraphApiDatasourceImpl.syncMailDelta — error handling', () {
    test('throws ServerException with statusCode 410 for expired token',
        () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 410,
          data: {
            'error': {'message': 'The sync state generation has expired.'}
          },
          requestOptions: RequestOptions(path: '/delta'),
        ),
        requestOptions: RequestOptions(path: '/delta'),
      ));

      await expectLater(
        datasource.syncMailDelta('inbox',
            deltaLink: 'https://graph.microsoft.com/v1.0/expired'),
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 410)),
      );
    });

    test('throws NetworkException on connection error', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.connectionError,
        requestOptions:
            RequestOptions(path: '/me/mailFolders/inbox/messages/delta'),
      ));

      await expectLater(
        datasource.syncMailDelta('inbox'),
        throwsA(isA<NetworkException>()),
      );
    });

    test('throws AuthException on 401', () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 401,
          data: {
            'error': {'message': 'Access token expired.'}
          },
          requestOptions: RequestOptions(path: '/delta'),
        ),
        requestOptions: RequestOptions(path: '/delta'),
      ));

      await expectLater(
        datasource.syncMailDelta('inbox'),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
