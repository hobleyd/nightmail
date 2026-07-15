import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'auth_interceptor.dart';

/// Dio instance pre-configured for the Google Calendar REST API.
class GoogleCalendarHttpClient {
  GoogleCalendarHttpClient({
    required AuthService authService,
    void Function()? onAuthFailure,
    void Function()? onAuthSuccess,
  }) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://www.googleapis.com/calendar/v3',
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
  }

  late final Dio _dio;

  Dio get dio => _dio;
}
