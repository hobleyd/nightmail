import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_shared_mailbox_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;

  setUp(() {
    mockDio = MockDio();
  });

  group('GraphApiDatasourceImpl mailbox routing', () {
    test('mailboxBase is /me when no mailboxAddress is given', () {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      expect(datasource.mailboxBase, '/me');
    });

    test('mailboxBase is /users/{address} for a shared mailbox', () {
      final datasource = GraphApiDatasourceImpl.withDio(
        mockDio,
        mailboxAddress: 'sales@corp.com',
      );
      expect(datasource.mailboxBase, '/users/sales@corp.com');
    });

    test('getEmails hits /me/messages by default', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: '{"value": []}',
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/messages'),
          ));

      await datasource.getEmails();

      final captured = verify(mockDio.get<String>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;
      expect(captured.single, '/me/messages');
    });

    test(
        'getEmails hits /users/{address}/messages for a shared mailbox — '
        'this is the whole point of mailboxAddress', () async {
      final datasource = GraphApiDatasourceImpl.withDio(
        mockDio,
        mailboxAddress: 'sales@corp.com',
      );
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: '{"value": []}',
            statusCode: 200,
            requestOptions: RequestOptions(path: '/users/sales@corp.com/messages'),
          ));

      await datasource.getEmails();

      final captured = verify(mockDio.get<String>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;
      expect(captured.single, '/users/sales@corp.com/messages');
    });
  });

  group('GraphApiDatasourceImpl.probeSharedMailboxAccess', () {
    test('returns true on 200 — the mailbox is reachable', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            data: {'id': 'inbox-id'},
            statusCode: 200,
            requestOptions:
                RequestOptions(path: '/users/sales@corp.com/mailFolders/inbox'),
          ));

      final result = await datasource.probeSharedMailboxAccess('sales@corp.com');

      expect(result, isTrue);
      final captured = verify(mockDio.get<Map<String, dynamic>>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
      )).captured;
      // Uri.encodeComponent percent-encodes '@' — correct and harmless for
      // Graph, which decodes the path segment the same way either side.
      expect(captured.single, '/users/sales%40corp.com/mailFolders/inbox');
    });

    test('returns false on 403 — no Full Access grant', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          statusCode: 403,
          requestOptions: RequestOptions(path: '/x'),
        ),
      ));

      final result = await datasource.probeSharedMailboxAccess('sales@corp.com');

      expect(result, isFalse);
    });

    test('returns false on 404 — not a mailbox at all', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          statusCode: 404,
          requestOptions: RequestOptions(path: '/x'),
        ),
      ));

      final result = await datasource.probeSharedMailboxAccess('nope@corp.com');

      expect(result, isFalse);
    });

    test('rethrows as ServerException on 500 — not silently "no access"', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          statusCode: 500,
          requestOptions: RequestOptions(path: '/x'),
        ),
      ));

      expect(
        () => datasource.probeSharedMailboxAccess('sales@corp.com'),
        throwsA(isA<ServerException>()),
      );
    });

    test('rethrows as NetworkException on a connection error', () async {
      final datasource = GraphApiDatasourceImpl.withDio(mockDio);
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenThrow(DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/x'),
        message: 'Failed host lookup',
      ));

      expect(
        () => datasource.probeSharedMailboxAccess('sales@corp.com'),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('linkedEventPath', () {
    test('defaults to /me', () {
      expect(
        linkedEventPath('msg-1'),
        '/me/messages/msg-1/microsoft.graph.eventMessage/event',
      );
    });

    test('uses the supplied mailbox base for a shared mailbox', () {
      expect(
        linkedEventPath('msg-1', '/users/sales@corp.com'),
        '/users/sales@corp.com/messages/msg-1/microsoft.graph.eventMessage/event',
      );
    });
  });
}
