import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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
  ///
  /// Fires only on an [AuthException]. A refresh that never reached the token
  /// endpoint throws [NetworkException] instead (see `tokenRefreshFailure`) and
  /// is deliberately *not* reported: an offline machine has not learnt anything
  /// about its credentials, and telling the user to sign in again is both wrong
  /// and something they cannot act on until the network is back.
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
    // A NetworkException from the refresh is left to propagate unreported: the
    // request fails as a network error (each datasource's _mapException unwraps
    // it) and the account keeps whatever auth state it already had.
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final opts = err.requestOptions;
    // The retry below comes back through here. Without the mark, a provider
    // that refuses even a freshly refreshed token was refreshed and retried
    // without end — a poll cycle that never completed, and no banner.
    if (err.response?.statusCode == 401 && opts.extra[_retriedKey] != true) {
      try {
        final storedToken = await authService.getStoredToken();
        if (storedToken?.refreshToken == null) {
          // Nothing to refresh with, so nothing short of a sign-in fixes it.
          debugPrint('[Auth] ${_describe(opts)} → 401 with no refresh token; '
              'flagging for sign-in');
          onAuthFailure?.call();
        } else {
          final fresh = await authService.refreshToken(storedToken!);
          opts.headers['Authorization'] =
              '${fresh.tokenType} ${fresh.accessToken}';
          opts.extra[_retriedKey] = true;
          try {
            final response = await dio.fetch(opts);
            onAuthSuccess?.call();
            handler.resolve(response);
            return;
          } on DioException catch (retryErr) {
            if (retryErr.response?.statusCode == 401) {
              // A token minted a moment ago and still refused: the grant
              // behind it is what is no longer accepted.
              debugPrint('[Auth] ${_describe(opts)} → 401 again on a freshly '
                  'refreshed token; flagging for sign-in');
              onAuthFailure?.call();
            } else {
              onAuthSuccess?.call();
            }
            handler.next(retryErr);
            return;
          }
        }
      } on AuthException catch (e) {
        debugPrint('[Auth] ${_describe(opts)} → 401, and the refresh was '
            'refused: ${e.message}');
        onAuthFailure?.call();
      } on NetworkException {
        // Offline mid-retry: pass the original 401 on rather than flagging the
        // account. The credentials may well be fine — we never got to ask.
      } catch (e) {
        debugPrint('[Auth] ${_describe(opts)} → 401, and the refresh failed: '
            '${e.runtimeType}: $e');
      }
    }
    handler.next(err);
  }

  /// Marks a request this interceptor has already refreshed and retried once.
  static const _retriedKey = 'nightmail.authRetried';

  static String _describe(RequestOptions o) => '${o.method} ${o.uri.path}';

  Future<AuthToken> _getValidToken() async {
    final stored = await authService.getStoredToken();

    if (stored == null) {
      throw const AuthException(message: 'Not authenticated. Please sign in.');
    }

    if (stored.isAboutToExpire && stored.refreshToken != null) {
      try {
        final refreshed = await authService.refreshToken(stored);
        onAuthSuccess?.call();
        return refreshed;
      } catch (e) {
        // The first request of a session is usually the one that has to do
        // this refresh, and a NetworkException here is reported nowhere else
        // by design (see [onAuthFailure]) — which makes it invisible as the
        // cause of a first load that fell back to the cache. Log it.
        final detail = switch (e) {
          AuthException(:final message) => message,
          NetworkException(:final message) => message,
          ServerException(:final message) => message,
          _ => '$e',
        };
        debugPrint(
            '[Auth] in-request token refresh failed: ${e.runtimeType} — $detail');
        rethrow;
      }
    }

    if (stored.isExpired) {
      throw const AuthException(message: 'Session expired. Please sign in again.');
    }

    return stored;
  }
}
