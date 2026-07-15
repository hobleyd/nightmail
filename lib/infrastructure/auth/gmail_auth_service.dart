import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/error/exceptions.dart';
import 'auth_service.dart';
import 'auth_token.dart';
import 'token_refresh_coordinator.dart';
import 'token_storage.dart';
import 'web_auth_stub.dart' if (dart.library.html) 'web_auth_web.dart';

/// Google OAuth2 + PKCE implementation for Gmail and Google Calendar access.
///
/// Requires a Google Cloud Console project with:
///   - Application type: Desktop app (allows loopback redirect on Windows/Linux)
///   - API permissions: Gmail API, Google Calendar API
class GmailAuthService implements AuthService {
  GmailAuthService({
    required this.clientId,
    required this.clientSecret,
    required this.redirectUri,
    required this._tokenStorage,
    Dio? httpClient,
  }) : _http = httpClient ?? Dio();

  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final TokenStorage _tokenStorage;
  final Dio _http;

  static const _scopes = [
    'openid',
    'profile',
    'email',
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/calendar.events',
    // Read-only access to calendarList entries (calendarList.get), needed to
    // resolve an event's reminders.useDefault into actual minutes — that
    // value lives on the CalendarList resource, not the Events resource
    // calendar.events grants access to. Without it, calendarList.get 403s
    // and every event using the calendar's default reminder (i.e. any event
    // without an explicit per-event override) silently gets no reminder.
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
    'https://www.googleapis.com/auth/tasks',
    'https://www.googleapis.com/auth/contacts.readonly',
    'https://www.googleapis.com/auth/contacts.other.readonly',
    'https://www.googleapis.com/auth/directory.readonly',
  ];

  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  // Windows and Linux use the loopback server approach.
  // Google accepts http://localhost (without port) as a registered redirect
  // URI for Desktop app registrations, and allows any port at runtime per
  // RFC 8252 §7.3.
  static const _loopbackPort = 34572;

  static bool get _useLoopback =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  String get _effectiveRedirectUri {
    if (kIsWeb) return '${Uri.base.origin}/callback.html';
    if (_useLoopback) return 'http://localhost:$_loopbackPort';
    return redirectUri;
  }

  @override
  Future<AuthToken> signIn() async {
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    final authUri = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': _effectiveRedirectUri,
        'scope': _scopes.join(' '),
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
      },
    );

    final String resultUrl;
    if (kIsWeb) {
      resultUrl = await authenticateWeb(authUri.toString());
    } else {
      final String callbackScheme = _useLoopback
          ? 'http://localhost:$_loopbackPort'
          : Uri.parse(redirectUri).scheme;
      final FlutterWebAuth2Options authOptions = _useLoopback
          ? const FlutterWebAuth2Options(useWebview: false)
          : const FlutterWebAuth2Options(preferEphemeral: true);

      resultUrl = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: callbackScheme,
        options: authOptions,
      );
    }

    final uri = Uri.parse(resultUrl);
    final code = uri.queryParameters['code'];
    final error = uri.queryParameters['error'];

    if (error != null) {
      final description = uri.queryParameters['error_description'] ?? error;
      throw AuthException(message: description);
    }

    if (code == null) {
      throw const AuthException(message: 'No authorization code received');
    }

    return _exchangeCodeForToken(code: code, codeVerifier: codeVerifier);
  }

  @override
  Future<AuthToken> refreshToken(AuthToken currentToken) {
    // Coalesce with any concurrent refresh for this account so a rotated
    // refresh token is never spent twice (see TokenRefreshCoordinator).
    return TokenRefreshCoordinator.coalesce(
      _tokenStorage.storageKey,
      () => _performRefresh(currentToken),
    );
  }

  Future<AuthToken> _performRefresh(AuthToken currentToken) async {
    // Another instance may have refreshed while this call was queued behind it.
    // If storage now holds a token that is no longer about to expire, reuse it
    // rather than spending our (now-stale) refresh token.
    final latest = await _tokenStorage.loadToken();
    if (latest != null &&
        latest.refreshToken != null &&
        !latest.isAboutToExpire) {
      return latest;
    }
    final effective = latest ?? currentToken;
    if (effective.refreshToken == null) {
      throw const AuthException(message: 'No refresh token available');
    }

    try {
      final response = await _http.post(
        _tokenEndpoint,
        data: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'refresh_token',
          'refresh_token': effective.refreshToken,
        },
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      final raw = AuthToken.fromJson(response.data as Map<String, dynamic>);
      // Google omits refresh_token from refresh responses; preserve the existing one.
      final token = raw.refreshToken != null
          ? raw
          : AuthToken(
              accessToken: raw.accessToken,
              expiresAt: raw.expiresAt,
              refreshToken: effective.refreshToken,
              tokenType: raw.tokenType,
              scope: raw.scope,
            );
      await _tokenStorage.saveToken(token);
      return token;
    } on DioException catch (e) {
      final message = _extractErrorMessage(e) ?? e.message ?? e.toString();
      throw AuthException(message: 'Token refresh failed: $message');
    }
  }

  @override
  Future<AuthToken?> getStoredToken() => _tokenStorage.loadToken();

  @override
  Future<void> signOut() async {
    await _tokenStorage.clearToken();
  }

  Future<AuthToken> _exchangeCodeForToken({
    required String code,
    required String codeVerifier,
  }) async {
    try {
      final response = await _http.post(
        _tokenEndpoint,
        data: {
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': _effectiveRedirectUri,
          'code_verifier': codeVerifier,
        },
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      final token = AuthToken.fromJson(response.data as Map<String, dynamic>);
      await _tokenStorage.saveToken(token);
      return token;
    } on DioException catch (e) {
      final message = _extractErrorMessage(e) ?? e.message ?? e.toString();
      throw AuthException(message: 'Token exchange failed: $message');
    }
  }

  String _generateCodeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(128, (_) => chars[random.nextInt(chars.length)])
        .join();
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64Url
        .encode(digest.bytes)
        .replaceAll('=', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
  }

  String? _extractErrorMessage(DioException e) {
    try {
      final data = e.response?.data;
      if (data is Map) {
        return data['error_description'] as String? ?? data['error'] as String?;
      }
    } catch (_) {}
    return null;
  }
}
