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
    final statusCode = err.response?.statusCode;
    if (statusCode != 429 && statusCode != 503) {
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
