import 'auth_token.dart';

/// Coalesces concurrent token refreshes that share the same storage key.
///
/// Several datasources for one account share a single [TokenStorage] key but
/// each hold their own [AuthService] + `AuthInterceptor`: the active account's
/// datasource, plus a *fresh* one the mail poller builds every cycle (see
/// `AccountManager.buildEmailDatasourceForAccount`), plus the calendar/tasks/
/// directory datasources. When the access token nears expiry, every request
/// triggers a refresh — and because Azure AD and Google *rotate* the refresh
/// token on each refresh, the first refresh invalidates the refresh token the
/// others are still holding. The losers then fail with `invalid_grant`, which
/// surfaces as an [AuthException] and spuriously flags the whole account as
/// needing re-authentication even though a valid token was just stored.
///
/// This serialises refreshes per key: while one is in flight, later callers
/// await its result instead of starting their own (which would double-spend
/// the rotated refresh token).
class TokenRefreshCoordinator {
  TokenRefreshCoordinator._();

  static final Map<String, Future<AuthToken>> _inFlight = {};

  /// Returns the in-flight refresh for [key] if one exists; otherwise runs
  /// [refresh], tracks it as in-flight, and clears it on completion.
  static Future<AuthToken> coalesce(
    String key,
    Future<AuthToken> Function() refresh,
  ) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = refresh();
    _inFlight[key] = future;
    return future.whenComplete(() {
      // Only clear if it is still our future — a later refresh may have already
      // replaced it (can't happen while one is in-flight, but guards resets).
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
  }
}
