import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/domain/entities/email.dart';

import 'graph_api_send_email_test.mocks.dart';

Response<void> _voidResp() => Response<void>(
      statusCode: 202,
      requestOptions: RequestOptions(path: '/me/sendMail'),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  group('GraphApiDatasourceImpl.sendEmail — request structure', () {
    test('posts to /me/sendMail', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Hello',
        body: 'Hi there',
      );

      verify(mockDio.post<void>('/me/sendMail', data: anyNamed('data')));
    });

    test('sets saveToSentItems to true', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      expect(body['saveToSentItems'], isTrue);
    });

    test('includes toRecipients with bare email addresses', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['alice@example.com', 'Bob Smith <bob@example.com>'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final to = (body['message'] as Map)['toRecipients'] as List;
      expect(to, hasLength(2));
      expect(to[0], {'emailAddress': {'address': 'alice@example.com'}});
      expect(to[1], {'emailAddress': {'address': 'bob@example.com'}});
    });
  });

  group('GraphApiDatasourceImpl.sendEmail — CC recipients', () {
    test('includes ccRecipients when ccAddresses is non-empty', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc@example.com'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final message = body['message'] as Map;
      expect(message.containsKey('ccRecipients'), isTrue);
      final cc = message['ccRecipients'] as List;
      expect(cc, hasLength(1));
      expect(cc[0], {'emailAddress': {'address': 'cc@example.com'}});
    });

    test('omits ccRecipients key when ccAddresses is empty', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final message = body['message'] as Map;
      expect(message.containsKey('ccRecipients'), isFalse);
    });

    test('strips display name from CC address', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        ccAddresses: ['Carol Jones <carol@example.com>'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final cc = (body['message'] as Map)['ccRecipients'] as List;
      expect(cc[0], {'emailAddress': {'address': 'carol@example.com'}});
    });

    test('sends multiple CC recipients', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc1@example.com', 'cc2@example.com'],
        subject: 'Subject',
        body: 'Body',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final cc = (body['message'] as Map)['ccRecipients'] as List;
      expect(cc, hasLength(2));
    });
  });

  group('GraphApiDatasourceImpl.sendEmail — body HTML conversion', () {
    test('sends body as text content type by default', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Hello',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final emailBody = (body['message'] as Map)['body'] as Map;
      expect(emailBody['contentType'], 'text');
    });

    test('sends body as HTML content type when bodyType is html', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>Hello</p>',
        bodyType: EmailBodyType.html,
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final emailBody = (body['message'] as Map)['body'] as Map;
      expect(emailBody['contentType'], 'html');
    });

    test('passes HTML body through unchanged', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>Line 1</p><p>Line 2</p>',
        bodyType: EmailBodyType.html,
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final content = (body['message'] as Map)['body']['content'] as String;
      expect(content, '<p>Line 1</p><p>Line 2</p>');
    });

    test('converts newlines to <br> tags', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Line 1\nLine 2\nLine 3',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final content = (body['message'] as Map)['body']['content'] as String;
      expect(content, 'Line 1<br>Line 2<br>Line 3');
    });

    test('escapes < and > characters', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Price: <100 & >50',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final content = (body['message'] as Map)['body']['content'] as String;
      expect(content, contains('&lt;100'));
      expect(content, contains('&gt;50'));
      expect(content, contains('&amp;'));
    });

    test('escapes ampersands', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'R&D team',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final content = (body['message'] as Map)['body']['content'] as String;
      expect(content, 'R&amp;D team');
    });

    test('preserves plain text with no special characters unchanged', () async {
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _voidResp());

      await datasource.sendEmail(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Just plain text',
      );

      final body = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final emailBody = (body['message'] as Map)['body'] as Map;
      expect(emailBody['contentType'], 'text');
      expect(emailBody['content'], 'Just plain text');
    });
  });

  group('GraphApiDatasourceImpl.sendEmail — error handling', () {
    test('throws NetworkException on connection error', () async {
      when(mockDio.post<void>(any, data: anyNamed('data'))).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: '/me/sendMail'),
        ),
      );

      await expectLater(
        datasource.sendEmail(
          toAddresses: ['to@example.com'],
          subject: 'Subject',
          body: 'Body',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('throws AuthException on 401', () async {
      when(mockDio.post<void>(any, data: anyNamed('data'))).thenThrow(
        DioException(
          type: DioExceptionType.badResponse,
          response: Response(
            statusCode: 401,
            data: {'error': {'message': 'Access token expired'}},
            requestOptions: RequestOptions(path: '/me/sendMail'),
          ),
          requestOptions: RequestOptions(path: '/me/sendMail'),
        ),
      );

      await expectLater(
        datasource.sendEmail(
          toAddresses: ['to@example.com'],
          subject: 'Subject',
          body: 'Body',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
