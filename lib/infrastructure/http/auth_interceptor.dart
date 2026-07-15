import 'package:dio/dio.dart';

import '../../core/error/exceptions.dart';
import '../auth/auth_service.dart';
import '../auth/auth_token.dart';

/// Dio interceptor that injects Bearer tokens and handles 401 by refreshing.
/// Shared by all HTTP clients (Graph, Gmail, Google Calendar).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.authService,
    required this.dio,
    this.onAuthFailure,
    this.onAuthSuccess,
  });

  final AuthService authService;
  final Dio dio;

  /// Notified whenever a token refresh fails (revoked/expired refresh token,
  /// missing admin consent, etc.). This is the single choke point every
  /// request for this account passes through, so it's the reliable place to
  /// surface "needs re-authentication" to the UI — relying on every caller of
  /// the datasource to individually catch AuthException is easy to miss.
  final void Function()? onAuthFailure;

  /// Notified whenever a token refresh succeeds. The mirror of [onAuthFailure]:
  /// it lets the UI clear a stale "needs re-authentication" flag that a
  /// *transient* refresh failure (e.g. a lost refresh-token rotation race)
  /// latched, so the flag self-heals the next time a refresh works. Fires only
  /// on an actual refresh — not on every request that reuses a still-valid
  /// token — since a plain request proves nothing new about the credentials.
  final void Function()? onAuthSuccess;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final token = await _getValidToken();
      options.headers['Authorization'] = '${token.tokenType} ${token.accessToken}';
      handler.next(options);
    } on AuthException {
      onAuthFailure?.call();
      rethrow;
    }
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
          onAuthSuccess?.call();
          final opts = err.requestOptions;
          opts.headers['Authorization'] =
              '${fresh.tokenType} ${fresh.accessToken}';
          final response = await dio.fetch(opts);
          handler.resolve(response);
          return;
        }
      } on AuthException {
        onAuthFailure?.call();
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
      final refreshed = await authService.refreshToken(stored);
      onAuthSuccess?.call();
      return refreshed;
    }

    if (stored.isExpired) {
      throw const AuthException(message: 'Session expired. Please sign in again.');
    }

    return stored;
  }
}
