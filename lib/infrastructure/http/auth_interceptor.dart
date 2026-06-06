import 'package:dio/dio.dart';

import '../../core/error/exceptions.dart';
import '../auth/auth_service.dart';
import '../auth/auth_token.dart';

/// Dio interceptor that injects Bearer tokens and handles 401 by refreshing.
/// Shared by all HTTP clients (Graph, Gmail, Google Calendar).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.authService, required this.dio});

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
