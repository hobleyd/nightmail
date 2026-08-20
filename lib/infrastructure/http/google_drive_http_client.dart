import 'package:dio/dio.dart';

import '../auth/auth_service.dart';
import 'auth_interceptor.dart';
import 'retry_interceptor.dart';

/// Dio instance pre-configured for the Google Drive REST API.
///
/// A generous receive timeout: unlike the metadata calls the other Google
/// clients make, this one downloads whole documents.
class GoogleDriveHttpClient {
  GoogleDriveHttpClient({
    required AuthService authService,
    void Function()? onAuthFailure,
    void Function()? onAuthSuccess,
  }) {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://www.googleapis.com/drive/v3',
      headers: {'Accept': 'application/json'},
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
    ));

    _dio.interceptors.add(AuthInterceptor(
        authService: authService,
        dio: _dio,
        onAuthFailure: onAuthFailure,
        onAuthSuccess: onAuthSuccess));
    _dio.interceptors.add(RetryInterceptor(dio: _dio));
  }

  late final Dio _dio;

  Dio get dio => _dio;
}
