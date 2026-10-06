import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_report_phishing_test.mocks.dart';

/// "Report phishing" on a Microsoft account is a threat submission — the same
/// channel Outlook's own Report button feeds — made *before* the message is
/// filed as junk, because the move mints a new id and the submission names the
/// message by the one it has now.
Response<Map<String, dynamic>> _json(Map<String, dynamic> data,
        {int statusCode = 200, String path = '/'}) =>
    Response<Map<String, dynamic>>(
      statusCode: statusCode,
      data: data,
      requestOptions: RequestOptions(path: path),
    );

DioException _http(int status, {Map<String, dynamic>? body}) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      statusCode: status,
      data: body,
      requestOptions: options,
    ),
  );
}

@GenerateMocks([Dio])
void main() {
  late MockDio dio;

  setUp(() {
    dio = MockDio();
  });

  group('the signed-in user\'s own mailbox', () {
    setUp(() {
      when(dio.get<Map<String, dynamic>>('/me',
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => _json({
                'id': 'user-guid',
                'mail': 'me@contoso.com',
                'userPrincipalName': 'me_contoso.com#EXT#@tenant.onmicrosoft.com',
              }));
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _json({'status': 'succeeded'}, statusCode: 201));
    });

    test('posts an emailUrlThreatSubmission of category phishing to the beta '
        'threat submission endpoint', () async {
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await ds.submitPhishingReport('AAMk-message');

      final captured = verify(dio.post<Map<String, dynamic>>(
              captureAny, data: captureAnyNamed('data')))
          .captured;
      expect(captured[0], GraphApiDatasourceImpl.threatSubmissionEndpoint);
      expect(captured[0], startsWith('https://graph.microsoft.com/beta/'));
      final body = captured[1] as Map<String, dynamic>;
      expect(body['@odata.type'],
          '#microsoft.graph.security.emailUrlThreatSubmission');
      expect(body['category'], 'phishing');
      // The beta property is `messageUrl`; `messageUri` belongs to v1.0's
      // unrelated threatAssessmentRequests.
      expect(body.containsKey('messageUri'), isFalse);
      expect(body['messageUrl'],
          'https://graph.microsoft.com/beta/users/user-guid/messages/AAMk-message');
    });

    test('names the recipient by the mailbox\'s `mail` address and the '
        'message by the user\'s directory id — an alias in `mail` is not a '
        'users/{…} key, the id always is', () async {
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await ds.submitPhishingReport('m1');

      final body = verify(dio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured
          .single as Map<String, dynamic>;
      expect(body['recipientEmailAddress'], 'me@contoso.com');
      expect(body['messageUrl'], contains('/users/user-guid/'));
    });

    test('falls back to the UPN when the directory has no `mail`', () async {
      when(dio.get<Map<String, dynamic>>('/me',
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => _json({
                'id': 'user-guid',
                'userPrincipalName': 'me@contoso.com',
              }));
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await ds.submitPhishingReport('m1');

      final body = verify(dio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured
          .single as Map<String, dynamic>;
      expect(body['recipientEmailAddress'], 'me@contoso.com');
    });

    test('resolves /me once per instance, not once per report', () async {
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await ds.submitPhishingReport('m1');
      await ds.submitPhishingReport('m2');

      verify(dio.get<Map<String, dynamic>>('/me',
              queryParameters: anyNamed('queryParameters')))
          .called(1);
      verify(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .called(2);
    });
  });

  group('a shared mailbox', () {
    test('is named by the address its base path already carries, with no '
        '/me lookup — /me would be the owner, not the mailbox', () async {
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _json({}, statusCode: 201));
      final ds = GraphApiDatasourceImpl.withDio(dio,
          mailboxAddress: 'shared@contoso.com');

      await ds.submitPhishingReport('m1');

      verifyNever(dio.get<Map<String, dynamic>>(any,
          queryParameters: anyNamed('queryParameters')));
      final body = verify(dio.post<Map<String, dynamic>>(any,
              data: captureAnyNamed('data')))
          .captured
          .single as Map<String, dynamic>;
      expect(body['recipientEmailAddress'], 'shared@contoso.com');
      expect(body['messageUrl'],
          'https://graph.microsoft.com/beta/users/shared@contoso.com/messages/m1');
    });
  });

  group('failures', () {
    test('a 403 — the tenant never consented to ThreatSubmission.ReadWrite — '
        'is a ServerException carrying Graph\'s own message', () async {
      when(dio.get<Map<String, dynamic>>('/me',
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => _json({
                'id': 'user-guid',
                'mail': 'me@contoso.com',
              }));
      when(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')))
          .thenThrow(_http(403, body: {
        'error': {'code': 'Forbidden', 'message': 'Insufficient privileges'}
      }));
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await expectLater(
        ds.submitPhishingReport('m1'),
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.message, 'message', 'Insufficient privileges')),
      );
    });

    test('a mailbox whose identity cannot be resolved is refused before '
        'anything is submitted', () async {
      when(dio.get<Map<String, dynamic>>('/me',
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => _json({}));
      final ds = GraphApiDatasourceImpl.withDio(dio);

      await expectLater(
          ds.submitPhishingReport('m1'), throwsA(isA<ServerException>()));
      verifyNever(dio.post<Map<String, dynamic>>(any, data: anyNamed('data')));
    });
  });
}
