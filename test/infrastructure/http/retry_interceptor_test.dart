import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/http/retry_interceptor.dart';

// Fake adapter that replays a scripted sequence of status codes, one per
// call, repeating the final entry once the script is exhausted.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.statusCodes, {this.retryAfterHeader});

  final List<int> statusCodes;
  final String? retryAfterHeader;
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = callCount < statusCodes.length ? callCount : statusCodes.length - 1;
    callCount++;
    final statusCode = statusCodes[index];
    final headers = statusCode == 429 && retryAfterHeader != null
        ? {'retry-after': [retryAfterHeader!]}
        : <String, List<String>>{};
    return ResponseBody.fromString('{}', statusCode, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('retries a 429 honouring Retry-After and eventually succeeds', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.httpClientAdapter = _ScriptedAdapter([429, 429, 200], retryAfterHeader: '0');
    dio.interceptors.add(RetryInterceptor(dio: dio));

    final response = await dio.get<String>('/messages');

    expect(response.statusCode, 200);
  });

  test('gives up after maxRetries and surfaces the failure', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.httpClientAdapter = _ScriptedAdapter([429, 429, 429], retryAfterHeader: '0');
    dio.interceptors.add(RetryInterceptor(dio: dio, maxRetries: 1));

    await expectLater(
      dio.get<String>('/messages'),
      throwsA(isA<DioException>().having(
          (e) => e.response?.statusCode, 'statusCode', 429)),
    );
  });
}
