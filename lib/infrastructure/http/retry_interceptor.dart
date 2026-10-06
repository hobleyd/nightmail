import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

/// Dio interceptor that retries requests throttled with 429 (or a transient
/// 503), honouring the server's `Retry-After` header when present.
///
/// Microsoft Graph enforces per-mailbox rate limits. Loops that issue many
/// sequential requests against the same mailbox (e.g. emptying a large
/// folder one message at a time) can trip this limit well before finishing;
/// without a retry the whole operation aborts partway through, silently
/// leaving the remainder of the work undone.
///
/// Gmail's per-user quota refusal is retried too, and it does **not** arrive
/// as a 429 — see [isThrottled].
class RetryInterceptor extends Interceptor {
  RetryInterceptor({required this.dio, this.maxRetries = 5});

  final Dio dio;
  final int maxRetries;

  static const _retryCountKey = 'retry_interceptor_attempt';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!isThrottled(err)) {
      handler.next(err);
      return;
    }

    final options = err.requestOptions;
    final attempt = (options.extra[_retryCountKey] as int? ?? 0) + 1;
    if (attempt > maxRetries) {
      handler.next(err);
      return;
    }

    await Future.delayed(_delayFor(attempt, err.response?.headers.value('retry-after')));

    try {
      options.extra[_retryCountKey] = attempt;
      final response = await dio.fetch(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  /// Whether [err] is the server asking for a pause rather than refusing the
  /// request.
  ///
  /// A 429 or 503 from anyone — and Gmail's per-user quota refusal, which
  /// Google sends as a **403** with reason `rateLimitExceeded` or
  /// `userRateLimitExceeded` ("Quota exceeded for quota metric 'Total Query
  /// Cost' and limit 'Units per minute per user'…"). That is the error every
  /// Gmail request gets the moment an account's 6,000 units a minute are spent,
  /// and because it is not a 429 it used to go straight through: the folder
  /// list and the page on screen failed outright instead of waiting the few
  /// seconds the window takes to roll over. A 403 for any other reason — a
  /// missing scope, Graph's forbidden, Gmail's `dailyLimitExceeded` — is final
  /// and is not retried: waiting would not change the answer.
  static bool isThrottled(DioException err) {
    final status = err.response?.statusCode;
    if (status == 429 || status == 503) return true;
    if (status != 403) return false;
    return _isGoogleRateLimit(err.response?.data);
  }

  static const _googleRateLimitReasons = {
    'rateLimitExceeded',
    'userRateLimitExceeded',
    'quotaExceeded',
  };

  static bool _isGoogleRateLimit(dynamic body) {
    try {
      var data = body;
      if (data is List<int>) data = utf8.decode(data);
      if (data is String) {
        if (data.isEmpty) return false;
        data = jsonDecode(data);
      }
      if (data is! Map) return false;
      final error = data['error'];
      if (error is! Map) return false;
      if (error['status'] == 'RESOURCE_EXHAUSTED') return true;
      for (final e in error['errors'] as List<dynamic>? ?? const []) {
        if (e is Map && _googleRateLimitReasons.contains(e['reason'])) {
          return true;
        }
      }
      for (final d in error['details'] as List<dynamic>? ?? const []) {
        if (d is Map && d['reason'] == 'RATE_LIMIT_EXCEEDED') return true;
      }
    } catch (_) {
      // Not a Google error body — not a rate limit we can recognise.
    }
    return false;
  }

  Duration _delayFor(int attempt, String? retryAfterHeader) {
    final retryAfterSeconds = retryAfterHeader != null ? int.tryParse(retryAfterHeader) : null;
    if (retryAfterSeconds != null) {
      return Duration(seconds: retryAfterSeconds);
    }
    // Exponential backoff with jitter: 1s, 2s, 4s, 8s, 16s (capped).
    final backoffSeconds = min(1 << attempt, 30);
    final jitterMs = Random().nextInt(500);
    return Duration(seconds: backoffSeconds, milliseconds: jitterMs);
  }
}
