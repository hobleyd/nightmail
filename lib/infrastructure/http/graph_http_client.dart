import 'package:dio/dio.dart';

import '../../core/error/exceptions.dart';
import '../auth/auth_service.dart';
import '../auth/auth_token.dart';

/// Dio instance pre-configured for Microsoft Graph API calls.
/// Automatically injects the Bearer token and refreshes it on 401.
class GraphHttpClient {
  GraphHttpClient({required AuthService authService})
      : _authService = authService {
    _dio = Dio(BaseOptions(
      baseUrl: 'https://graph.microsoft.com/v1.0',
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));

    _dio.interceptors.add(_AuthInterceptor(authService: _authService, dio: _dio));
  }

  late final Dio _dio;
  final AuthService _authService;

  Dio get dio => _dio;
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor({required this.authService, required this.dio});

  final AuthService authService;
  final Dio dio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _getValidToken();
    options.headers['Authorization'] = '${token.tokenType} ${token.accessToken}';
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode == 401) {
      try {
        final storedToken = await authService.getStoredToken();
        if (storedToken?.refreshToken != null) {
          final fresh = await authService.refreshToken(storedToken!);
          final opts = err.requestOptions;
          opts.headers['Authorization'] =
              '${fresh.tokenType} ${fresh.accessToken}';
          final response = await dio.fetch(opts);
          handler.resolve(response);
          return;
        }
      } catch (_) {}
    }
    handler.next(err);
  }

  Future<AuthToken> _getValidToken() async {
    final stored = await authService.getStoredToken();

    if (stored == null) {
      throw const AuthException(message: 'Not authenticated. Please sign in.');
    }

    if (stored.isAboutToExpire && stored.refreshToken != null) {
      return authService.refreshToken(stored);
    }

    if (stored.isExpired) {
      throw const AuthException(message: 'Session expired. Please sign in again.');
    }

    return stored;
  }
}
