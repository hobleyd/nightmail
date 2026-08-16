import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_insert_raw_message_test.mocks.dart';

final _rawBytes = Uint8List.fromList(
  'From: Sender <sender@example.com>\r\n'
  'To: dest@example.com\r\n'
  'Subject: Hello\r\n'
  '\r\n'
  'Body text'
      .codeUnits,
);

Response<Map<String, dynamic>> _createdResp({String id = 'new-msg-id'}) =>
    Response<Map<String, dynamic>>(
      statusCode: 201,
      data: {'id': id},
      requestOptions: RequestOptions(path: '/mailFolders/inbox/messages'),
    );

DioException _badResponse(int statusCode) => DioException(
      type: DioExceptionType.badResponse,
      response: Response(
        statusCode: statusCode,
        data: {
          'error': {'message': 'nope'}
        },
        requestOptions: RequestOptions(path: '/mailFolders/inbox/messages'),
      ),
      requestOptions: RequestOptions(path: '/mailFolders/inbox/messages'),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  group('GraphApiDatasourceImpl.insertRawMessage — from field', () {
    test('sets the structured from field on the first attempt', () async {
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _createdResp());

      await datasource.insertRawMessage(
        folderId: 'inbox',
        rawBytes: _rawBytes,
        receivedAt: DateTime.utc(2026, 1, 1),
        isRead: true,
      );

      final captured = verify(mockDio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured;
      expect(captured, hasLength(1));
      final body = captured.single as Map<String, dynamic>;
      expect(body['from'], isNotNull);
      expect((body['from'] as Map)['emailAddress'],
          {'address': 'sender@example.com', 'name': 'Sender'});
    });

    // A destination mailbox routinely has no SendAs right over the source
    // account's address — Graph can reject the whole create call over the
    // 'from' field rather than merely dropping it, which would otherwise
    // fail every single message migrated onto an O365 destination.
    test('retries once without from on a 400 and still returns the id',
        () async {
      var call = 0;
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((invocation) async {
        call++;
        if (call == 1) throw _badResponse(400);
        return _createdResp(id: 'retried-id');
      });

      final id = await datasource.insertRawMessage(
        folderId: 'inbox',
        rawBytes: _rawBytes,
        receivedAt: DateTime.utc(2026, 1, 1),
        isRead: true,
      );

      expect(id, 'retried-id');
      final captured = verify(mockDio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured;
      expect(captured, hasLength(2));
      expect((captured[0] as Map).containsKey('from'), isTrue);
      expect((captured[1] as Map).containsKey('from'), isFalse);
    });

    test('retries once without from on a 403', () async {
      var call = 0;
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((invocation) async {
        call++;
        if (call == 1) throw _badResponse(403);
        return _createdResp();
      });

      await datasource.insertRawMessage(
        folderId: 'inbox',
        rawBytes: _rawBytes,
        receivedAt: DateTime.utc(2026, 1, 1),
        isRead: true,
      );

      verify(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .called(2);
    });

    test('does not retry and propagates a 401', () async {
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(_badResponse(401));

      await expectLater(
        datasource.insertRawMessage(
          folderId: 'inbox',
          rawBytes: _rawBytes,
          receivedAt: DateTime.utc(2026, 1, 1),
          isRead: true,
        ),
        throwsA(isA<Exception>()),
      );

      verify(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .called(1);
    });

    test('does not retry and propagates a 503', () async {
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(_badResponse(503));

      await expectLater(
        datasource.insertRawMessage(
          folderId: 'inbox',
          rawBytes: _rawBytes,
          receivedAt: DateTime.utc(2026, 1, 1),
          isRead: true,
        ),
        throwsA(isA<Exception>()),
      );

      verify(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .called(1);
    });

    test('a second consecutive rejection still propagates', () async {
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(_badResponse(400));

      await expectLater(
        datasource.insertRawMessage(
          folderId: 'inbox',
          rawBytes: _rawBytes,
          receivedAt: DateTime.utc(2026, 1, 1),
          isRead: true,
        ),
        throwsA(isA<Exception>()),
      );

      verify(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .called(2);
    });
  });

  group('GraphApiDatasourceImpl.insertRawMessage — dates', () {
    test('sets receivedDateTime and sentDateTime from receivedAt', () async {
      when(mockDio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _createdResp());

      await datasource.insertRawMessage(
        folderId: 'inbox',
        rawBytes: _rawBytes,
        receivedAt: DateTime.utc(2026, 3, 4, 5, 6, 7),
        isRead: false,
      );

      final body = verify(mockDio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured
          .single as Map<String, dynamic>;
      expect(body['receivedDateTime'], '2026-03-04T05:06:07.000Z');
      expect(body['sentDateTime'], '2026-03-04T05:06:07.000Z');
      expect(body['isRead'], isFalse);
    });
  });
}
