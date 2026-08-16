import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'auth_interceptor.dart';
import 'retry_interceptor.dart';

/// Dio instance pre-configured for the Gmail REST API.
class GmailHttpClient {
  GmailHttpClient({
    required AuthService authService,
    void Function()? onAuthFailure,
    void Function()? onAuthSuccess,
  }) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://gmail.googleapis.com/gmail/v1',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));

    _dio.interceptors.add(AuthInterceptor(
        authService: authService,
        dio: _dio,
        onAuthFailure: onAuthFailure,
        onAuthSuccess: onAuthSuccess));
    // Gmail enforces its own per-user rate limits same as Graph — without
    // this, a burst of requests (e.g. account migration) gets no 429/503
    // backoff at the HTTP layer at all.
    _dio.interceptors.add(RetryInterceptor(dio: _dio));
  }

  late final Dio _dio;

  Dio get dio => _dio;
}
