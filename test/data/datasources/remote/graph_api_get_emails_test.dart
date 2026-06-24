import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_get_emails_test.mocks.dart';

Map<String, dynamic> _messageJson(String id, String convId) => {
      'id': id,
      'subject': 'Test',
      'from': {
        'emailAddress': {'address': 'a@b.com', 'name': 'A'}
      },
      'toRecipients': <dynamic>[],
      'ccRecipients': <dynamic>[],
      'bodyPreview': '',
      'isRead': true,
      'receivedDateTime': '2026-01-01T00:00:00Z',
      'importance': 'normal',
      'conversationId': convId,
      'hasAttachments': false,
      'parentFolderId': 'inbox',
    };

Response<Map<String, dynamic>> _resp(
  Map<String, dynamic> data, {
  String path = '',
}) =>
    Response(
      data: data,
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

  // Regression: _fetchConversationMessages previously used $top: 50, which
  // silently truncated threads with more than 50 messages.  Those unloaded
  // messages were never moved when the user dragged the thread, leaving them
  // in the source folder so the thread reappeared after a refresh.
  group('getEmails — _fetchConversationMessages uses \$top: 200', () {
    test('passes \$top: 200 when fetching cross-folder conversation messages',
        () async {
      // First call: folder messages (contains one email with a conversationId).
      when(mockDio.get<Map<String, dynamic>>(
        '/me/mailFolders/inbox/messages',
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => _resp({
            'value': [_messageJson('msg1', 'conv-1')],
          }));

      // Second call: _fetchConversationMessages for conv-1.
      // Capture the queryParameters so we can assert on $top.
      Map<String, dynamic>? capturedParams;
      when(mockDio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((invocation) async {
        capturedParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>?;
        return _resp({'value': <dynamic>[]});
      });

      await datasource.getEmails(folderId: 'inbox', top: 1);

      expect(capturedParams, isNotNull,
          reason: '_fetchConversationMessages was not called');
      expect(capturedParams!['\$top'], equals(200),
          reason:
              '\$top should be 200 so large threads are fully fetched before a drag-move');
    });

    test('conversation fetch uses \$filter with the correct conversationId',
        () async {
      when(mockDio.get<Map<String, dynamic>>(
        '/me/mailFolders/inbox/messages',
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => _resp({
            'value': [_messageJson('msg1', 'my-conv-id')],
          }));

      Map<String, dynamic>? capturedParams;
      when(mockDio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((invocation) async {
        capturedParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>?;
        return _resp({'value': <dynamic>[]});
      });

      await datasource.getEmails(folderId: 'inbox', top: 1);

      expect(capturedParams!['\$filter'],
          equals("conversationId eq 'my-conv-id'"));
    });
  });
}
