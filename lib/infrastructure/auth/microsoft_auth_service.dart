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
import 'token_storage.dart';
import 'web_auth_stub.dart' if (dart.library.html) 'web_auth_web.dart';

/// Microsoft identity platform OAuth2 + PKCE implementation.
///
/// Requires an Azure AD app registration with:
///   - Platform: Mobile and Desktop (for native/desktop), or Single-page
///     application (for web)
///   - Redirect URI matching [redirectUri]
///   - API permissions: Mail.Read, Mail.ReadWrite, Mail.Send, Calendars.ReadWrite, Tasks.ReadWrite, offline_access
class MicrosoftAuthService implements AuthService {
  MicrosoftAuthService({
    required this.clientId,
    required this.tenantId,
    required this.redirectUri,
    required this._tokenStorage,
    this.clientSecret,
    Dio? httpClient,
  })  : _http = httpClient ?? Dio();

  final String clientId;
  final String tenantId;
  final String redirectUri;
  final String? clientSecret;
  final TokenStorage _tokenStorage;
  final Dio _http;

  // On Windows, open the system browser with a localhost loopback redirect.
  // Microsoft Azure AD accepts any http://localhost:{port} for public-client
  // (Mobile and Desktop) app registrations without needing to pre-register the
  // specific port — RFC 8252 §7.3 / MSAL loopback support.
  //
  // On web: serve callback.html from the same origin so the BroadcastChannel
  // can relay the code back. On other native platforms: use the custom URI
  // scheme that ASWebAuthenticationSession / Custom Tabs intercept.
  static const _loopbackPort = 34571;

  // Windows and Linux use the local server approach (same underlying plugin).
  // macOS/iOS use ASWebAuthenticationSession; Android uses Custom Tabs.
  // Both handle nightmail:// custom scheme intercepts natively, so they use
  // the stored redirectUri instead.
  static bool get _useLoopback =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  String get _effectiveRedirectUri {
    if (kIsWeb) {
      return '${Uri.base.origin}/callback.html';
    }
    if (_useLoopback) {
      return 'http://localhost:$_loopbackPort';
    }
    return redirectUri;
  }

  static const _scopes = [
    'openid',
    'profile',
    'email',
    'offline_access',
    'https://graph.microsoft.com/User.Read',
    'https://graph.microsoft.com/Mail.Read',
    'https://graph.microsoft.com/Mail.ReadWrite',
    'https://graph.microsoft.com/Mail.Send',
    'https://graph.microsoft.com/MailboxSettings.Read',
    'https://graph.microsoft.com/Calendars.ReadWrite',
    'https://graph.microsoft.com/Tasks.ReadWrite',
    'https://graph.microsoft.com/User.Read.All',
  ];

  String get _baseUrl =>
      'https://login.microsoftonline.com/$tenantId/oauth2/v2.0';

  @override
  Future<AuthToken> signIn() async {
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    final authUri = Uri.parse('$_baseUrl/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': _effectiveRedirectUri,
        'scope': _scopes.join(' '),
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'response_mode': 'query',
      },
    );

    // On web, flutter_web_auth_2 is bypassed because Microsoft's COOP headers
    // sever window.opener in the popup, breaking its postMessage approach.
    // We use BroadcastChannel instead (see web_auth_web.dart / callback.html).
    //
    // preferEphemeral=true: on macOS without a sandbox, ASWebAuthenticationSession
    // would otherwise try to share session cookies via the Keychain (requiring
    // keychain-access-groups entitlement). Ephemeral mode skips that store.
    assert(() {
      // ignore: avoid_print
      print('[MicrosoftAuth] tenantId=$tenantId clientId=$clientId redirectUri=$_effectiveRedirectUri');
      // ignore: avoid_print
      print('[MicrosoftAuth] Opening: ${authUri.toString()}');
      return true;
    }());

    final String resultUrl;
    if (kIsWeb) {
      resultUrl = await authenticateWeb(authUri.toString());
    } else {
      // Windows/Linux: open the system browser + local server instead of
      // WebView2/WebKitGTK, which don't reliably fire NavigationStarting for
      // custom URI scheme redirects.
      // macOS/iOS/Android: ASWebAuthenticationSession / Custom Tabs handle
      // the nightmail:// intercept natively so WebView is not needed.
      final String callbackScheme = _useLoopback
          ? 'http://localhost:$_loopbackPort'
          : 'nightmail';
      final FlutterWebAuth2Options authOptions = _useLoopback
          ? const FlutterWebAuth2Options(useWebview: false)
          : const FlutterWebAuth2Options(preferEphemeral: true);

      try {
        resultUrl = await FlutterWebAuth2.authenticate(
          url: authUri.toString(),
          callbackUrlScheme: callbackScheme,
          options: authOptions,
        );
        assert(() {
          // ignore: avoid_print
          print('[MicrosoftAuth] Callback received: $resultUrl');
          return true;
        }());
      } catch (e) {
        assert(() {
          // ignore: avoid_print
          print('[MicrosoftAuth] Auth failed: $e');
          return true;
        }());
        rethrow;
      }
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
        '$_baseUrl/token',
        data: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': currentToken.refreshToken,
          'scope': _scopes.join(' '),
          'redirect_uri': _effectiveRedirectUri,
          if (clientSecret != null && clientSecret!.isNotEmpty)
            'client_secret': clientSecret!,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
      );

      final raw = AuthToken.fromJson(response.data as Map<String, dynamic>);
      // Microsoft may omit refresh_token from refresh responses; preserve the existing one.
      final token = raw.refreshToken != null
          ? raw
          : AuthToken(
              accessToken: raw.accessToken,
              expiresAt: raw.expiresAt,
              refreshToken: currentToken.refreshToken,
              tokenType: raw.tokenType,
              scope: raw.scope,
            );
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
        '$_baseUrl/token',
        data: {
          'client_id': clientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': _effectiveRedirectUri,
          'code_verifier': codeVerifier,
          if (clientSecret != null && clientSecret!.isNotEmpty)
            'client_secret': clientSecret!,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
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
        return data['error_description'] as String? ??
            data['error'] as String?;
      }
    } catch (_) {}
    return null;
  }
}
