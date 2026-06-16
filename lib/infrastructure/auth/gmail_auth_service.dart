import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/error/exceptions.dart';
import 'auth_service.dart';
import 'auth_token.dart';
import 'token_storage.dart';
import 'web_auth_stub.dart' if (dart.library.html) 'web_auth_web.dart';

/// Google OAuth2 + PKCE implementation for Gmail and Google Calendar access.
class GmailAuthService implements AuthService {
  GmailAuthService({
    required this.clientId,
    required this.redirectUri,
    required this._tokenStorage,
    this.clientSecret,
    Dio? httpClient,
  })  : _http = httpClient ?? Dio();

  final String clientId;
  final String redirectUri;
  final String? clientSecret;
  final TokenStorage _tokenStorage;
  final Dio _http;

  static const _scopes = [
    'openid',
    'profile',
    'email',
    'offline_access',
    'https://www.googleapis.com/auth/gmail.modify',
    'https://www.googleapis.com/auth/calendar.readonly',
  ];

  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  String get _callbackUrlScheme {
    final uri = Uri.parse(redirectUri);
    return uri.scheme;
  }

  @override
  Future<AuthToken> signIn() async {
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    final authUri = Uri.parse(_authEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': _scopes.join(' '),
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
      },
    );

    // preferEphemeral=true: on macOS without a sandbox, ASWebAuthenticationSession
    // would try to share session cookies via the Keychain (requiring the
    // keychain-access-groups entitlement). Ephemeral mode skips that store.
    final String resultUrl;
    if (kIsWeb) {
      resultUrl = await authenticateWeb(authUri.toString());
    } else {
      resultUrl = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: _callbackUrlScheme,
        options: const FlutterWebAuth2Options(preferEphemeral: true),
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
  Future<AuthToken> refreshToken(AuthToken currentToken) async {
    if (currentToken.refreshToken == null) {
      throw const AuthException(message: 'No refresh token available');
    }

    try {
      final response = await _http.post(
        _tokenEndpoint,
        data: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': currentToken.refreshToken,
          if (clientSecret != null && clientSecret!.isNotEmpty)
            'client_secret': clientSecret!,
        },
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      final token = AuthToken.fromJson(response.data as Map<String, dynamic>);
      await _tokenStorage.saveToken(token);
      return token;
    } on DioException catch (e) {
      throw AuthException(
          message: 'Token refresh failed: ${e.message ?? e.toString()}');
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
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': codeVerifier,
          if (clientSecret != null && clientSecret!.isNotEmpty)
            'client_secret': clientSecret!,
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
