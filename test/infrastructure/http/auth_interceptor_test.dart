import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/auth/auth_service.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/http/auth_interceptor.dart';

/// Answers every request with [statusCode], counting them.
class _FixedStatusAdapter implements HttpClientAdapter {
  _FixedStatusAdapter(this.statusCode);

  final int statusCode;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    // A safety net for the regression below, which used to never stop.
    if (calls > 20) return ResponseBody.fromString('{}', 599);
    return ResponseBody.fromString('{}', statusCode);
  }

  @override
  void close({bool force = false}) {}
}

/// Holds a token whose refresh always succeeds.
class _RefreshingAuthService implements AuthService {
  _RefreshingAuthService({this.hasRefreshToken = true});

  final bool hasRefreshToken;
  int refreshes = 0;

  AuthToken get _token => AuthToken(
        accessToken: 'access',
        refreshToken: hasRefreshToken ? 'refresh' : null,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

  @override
  Future<AuthToken?> getStoredToken() async => _token;

  @override
  Future<AuthToken> refreshToken(AuthToken currentToken) async {
    refreshes++;
    return _token;
  }

  @override
  Future<AuthToken> signIn() => throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}

void main() {
  late Dio dio;
  late int failures;
  late int successes;

  void wire(AuthService auth, HttpClientAdapter adapter) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(AuthInterceptor(
      authService: auth,
      dio: dio,
      onAuthFailure: () => failures++,
      onAuthSuccess: () => successes++,
    ));
  }

  setUp(() {
    failures = 0;
    successes = 0;
  });

  // Regression: the retry went back through this interceptor, so a provider
  // that kept refusing a freshly refreshed token was refreshed and retried
  // without end — and the account was never flagged, so no banner said why.
  test('a 401 that survives a refresh is retried once and flags the account',
      () async {
    final adapter = _FixedStatusAdapter(401);
    final auth = _RefreshingAuthService();
    wire(auth, adapter);

    await expectLater(
      dio.get<String>('/messages'),
      throwsA(isA<DioException>()
          .having((e) => e.response?.statusCode, 'status', 401)),
    );

    expect(adapter.calls, 2, reason: 'the request and one retry');
    expect(auth.refreshes, 1);
    expect(failures, 1);
    expect(successes, 0,
        reason: 'a refresh the provider still refuses proves nothing');
  });

  test('a 401 with no refresh token to try flags the account', () async {
    final adapter = _FixedStatusAdapter(401);
    final auth = _RefreshingAuthService(hasRefreshToken: false);
    wire(auth, adapter);

    await expectLater(dio.get<String>('/messages'), throwsA(isA<DioException>()));

    expect(adapter.calls, 1);
    expect(failures, 1);
  });

  test('a 401 the refresh cures is retried and reported as a success',
      () async {
    var calls = 0;
    final adapter = _CallbackAdapter((_) => ++calls == 1 ? 401 : 200);
    final auth = _RefreshingAuthService();
    wire(auth, adapter);

    final response = await dio.get<String>('/messages');

    expect(response.statusCode, 200);
    expect(successes, 1);
    expect(failures, 0);
  });
}

class _CallbackAdapter implements HttpClientAdapter {
  _CallbackAdapter(this.statusFor);

  final int Function(RequestOptions) statusFor;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString('{}', statusFor(options));

  @override
  void close({bool force = false}) {}
}
