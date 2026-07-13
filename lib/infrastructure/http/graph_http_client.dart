import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'auth_interceptor.dart';
import 'retry_interceptor.dart';

/// Dio instance pre-configured for Microsoft Graph API calls.
/// Automatically injects the Bearer token and refreshes it on 401.
class GraphHttpClient {
  GraphHttpClient({required AuthService authService, void Function()? onAuthFailure}) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://graph.microsoft.com/v1.0',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));

    _dio.interceptors.add(AuthInterceptor(
        authService: authService, dio: _dio, onAuthFailure: onAuthFailure));
    _dio.interceptors.add(RetryInterceptor(dio: _dio));
  }

  late final Dio _dio;

  Dio get dio => _dio;
}
