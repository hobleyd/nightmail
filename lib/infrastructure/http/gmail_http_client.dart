import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'auth_interceptor.dart';

/// Dio instance pre-configured for the Gmail REST API.
class GmailHttpClient {
  GmailHttpClient({required AuthService authService}) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://gmail.googleapis.com/gmail/v1',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));

    _dio.interceptors.add(AuthInterceptor(authService: authService, dio: _dio));
  }

  late final Dio _dio;

  Dio get dio => _dio;
}
