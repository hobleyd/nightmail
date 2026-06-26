import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/ai/provider_models_datasource.dart';

import 'provider_models_datasource_test.mocks.dart';

Response<Map<String, dynamic>> _resp(Map<String, dynamic> data) => Response(
      data: data,
      statusCode: 200,
      requestOptions: RequestOptions(path: ''),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late ProviderModelsDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = ProviderModelsDatasourceImpl(dio: mockDio);
  });

  group('list — OpenAI-compatible path', () {
    test('GETs {base}/models with a Bearer header and parses data[].id',
        () async {
      String? capturedUrl;
      Options? capturedOptions;
      Map<String, dynamic>? capturedQuery;
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedUrl = invocation.positionalArguments[0] as String;
        capturedQuery =
            invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
        capturedOptions = invocation.namedArguments[#options] as Options?;
        // Returned out of order to prove the impl sorts the ids.
        return _resp({
          'data': [
            {'id': 'gpt-4o-mini'},
            {'id': 'gpt-4o'},
          ],
        });
      });

      final ids = await datasource.list(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
      );

      expect(ids, ['gpt-4o', 'gpt-4o-mini']);
      expect(capturedUrl, 'https://api.openai.com/v1/models');
      // OpenAI path sends no query parameters.
      expect(capturedQuery, isNull);
      expect(capturedOptions?.headers, {'Authorization': 'Bearer sk-test'});
    });

    test('strips a trailing slash from the base URL before appending /models',
        () async {
      String? capturedUrl;
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedUrl = invocation.positionalArguments[0] as String;
        return _resp({'data': <dynamic>[]});
      });

      await datasource.list(
        baseUrl: 'http://localhost:11434/v1/',
        apiKey: 'sk-test',
      );

      expect(capturedUrl, 'http://localhost:11434/v1/models');
    });

    test('omits the Authorization header when no API key is supplied', () async {
      Options? capturedOptions;
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedOptions = invocation.namedArguments[#options] as Options?;
        return _resp({'data': <dynamic>[]});
      });

      await datasource.list(baseUrl: 'http://localhost:11434/v1');

      expect(capturedOptions?.headers, isEmpty);
    });

    test('returns an empty list when the response has no data array', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({'object': 'list'}));

      final ids = await datasource.list(baseUrl: 'https://api.openai.com/v1');

      expect(ids, isEmpty);
    });
  });

  group('list — Azure deployments path', () {
    test(
        'GETs {root}/openai/deployments with api-version and the api-key header, '
        'parsing deployment ids', () async {
      String? capturedUrl;
      Options? capturedOptions;
      Map<String, dynamic>? capturedQuery;
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedUrl = invocation.positionalArguments[0] as String;
        capturedQuery =
            invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
        capturedOptions = invocation.namedArguments[#options] as Options?;
        return _resp({
          'data': [
            {'id': 'my-gpt-4o-deployment'},
            {'id': 'my-embedding-deployment'},
          ],
        });
      });

      final ids = await datasource.list(
        baseUrl: 'https://my-resource.openai.azure.com/openai/v1',
        apiKey: 'azure-key',
        azure: true,
      );

      expect(ids, ['my-embedding-deployment', 'my-gpt-4o-deployment']);
      // The `/openai/v1` suffix is stripped back to the resource root.
      expect(capturedUrl, 'https://my-resource.openai.azure.com/openai/deployments');
      expect(capturedQuery, {'api-version': '2023-03-15-preview'});
      // Azure authenticates with `api-key`, never `Authorization`.
      expect(capturedOptions?.headers, {'api-key': 'azure-key'});
      expect(capturedOptions?.headers?.containsKey('Authorization'), isFalse);
    });
  });

  group('list — DioException mapping', () {
    test('maps a connection error to NetworkException', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
        message: 'no route to host',
      ));

      expect(
        () => datasource.list(baseUrl: 'https://api.openai.com/v1'),
        throwsA(isA<NetworkException>()),
      );
    });

    test('maps a receive timeout to NetworkException', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.receiveTimeout,
      ));

      expect(
        () => datasource.list(baseUrl: 'https://api.openai.com/v1'),
        throwsA(isA<NetworkException>()),
      );
    });

    test('maps a bad-response error to ServerException carrying the status code',
        () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.badResponse,
        message: 'unauthorized',
        response: Response(
          requestOptions: RequestOptions(path: ''),
          statusCode: 401,
        ),
      ));

      await expectLater(
        () => datasource.list(baseUrl: 'https://api.openai.com/v1'),
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('does not let a raw DioException escape', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.unknown,
      ));

      await expectLater(
        () => datasource.list(baseUrl: 'https://api.openai.com/v1'),
        throwsA(isNot(isA<DioException>())),
      );
    });
  });
}
