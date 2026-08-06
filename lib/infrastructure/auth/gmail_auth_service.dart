import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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
    this.accountEmail,
    Dio? httpClient,
  }) : _http = httpClient ?? Dio();

  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final TokenStorage _tokenStorage;
  final Dio _http;

  /// The account being signed in, when it is already known — i.e. every path
  /// except adding a brand-new account. Used only to decide whether the
  /// Workspace-admin room scope may be requested; see [_requestedScopes].
  final String? accountEmail;

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
    // Free/busy lookups for meeting guests (freeBusy.query). calendar.events
    // does not cover it, so without this the scheduling assistant has no data
    // to show for a Gmail account. Accounts authorised before this scope was
    // added keep a token without it and 403 until they are signed in again —
    // GoogleCalendarDatasourceImpl.getAttendeesSchedule degrades to "unknown"
    // rather than surfacing an error in that case.
    'https://www.googleapis.com/auth/calendar.freebusy',
    'https://www.googleapis.com/auth/tasks',
    'https://www.googleapis.com/auth/contacts.readonly',
    'https://www.googleapis.com/auth/contacts.other.readonly',
    'https://www.googleapis.com/auth/directory.readonly',
  ];

  /// Lists the Workspace tenant's bookable rooms (Admin SDK
  /// `resources.calendars.list`) for the event form's Location picker.
  ///
  /// Deliberately *not* in [_scopes]: Google rejects the whole authorization
  /// request with `invalid_scope` when an `admin.directory.*` scope is asked for
  /// on a personal @gmail.com account, which would break adding one entirely.
  /// So it is only appended once we know the account is on a Workspace domain —
  /// see [_requestedScopes].
  static const _roomDirectoryScope =
      'https://www.googleapis.com/auth/admin.directory.resource.calendar.readonly';

  /// Google's consumer domains. Anything else is a Workspace (or Cloud Identity)
  /// domain, where the room scope is at worst refused by the API rather than by
  /// the authorization endpoint.
  static const _consumerDomains = {'gmail.com', 'googlemail.com'};

  /// The scopes to ask for, which depend on whether we already know who is
  /// signing in.
  ///
  /// Adding a new account cannot know — the whole point of the flow is to find
  /// out — so it asks for [_scopes] only, and that account's room picker falls
  /// back to the resource calendars the user has subscribed to
  /// (`GoogleCalendarDatasourceImpl._fetchRoomsFromCalendarList`). Signing the
  /// same account in again from Settings *does* know, and a Workspace account
  /// picks up [_roomDirectoryScope] then. Non-admin Workspace users are granted
  /// the scope and still get 403 from the Admin SDK, which is handled the same
  /// way as not having it.
  List<String> get _requestedScopes => scopesForAccount(accountEmail);

  @visibleForTesting
  static List<String> scopesForAccount(String? accountEmail) {
    final email = accountEmail?.trim().toLowerCase();
    if (email == null || !email.contains('@')) return _scopes;
    final domain = email.split('@').last;
    if (domain.isEmpty || _consumerDomains.contains(domain)) return _scopes;
    return [..._scopes, _roomDirectoryScope];
  }

  /// Visible for testing so the gating above can be asserted without driving a
  /// browser flow — getting it wrong breaks adding a personal Gmail account.
  @visibleForTesting
  static String get roomDirectoryScope => _roomDirectoryScope;

  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';

  // Windows and Linux use the loopback server approach.
  // Google accepts the loopback IP (with any port) as a redirect URI for
  // Desktop app registrations at runtime per RFC 8252 §7.3 — no Console
  // registration required.
  //
  // Use the literal 127.0.0.1, NOT "localhost": flutter_web_auth_2's desktop
  // server binds only to IPv4 127.0.0.1, but on Windows "localhost" often
  // resolves to the IPv6 loopback (::1) first. The browser then redirects to
  // a socket nothing is listening on, the callback never arrives, and
  // authenticate() hangs until timeout — the sign-in silently fails.
  static const _loopbackPort = 34572;
  static const _loopbackRedirect = 'http://127.0.0.1:$_loopbackPort';

  static bool get _useLoopback =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  String get _effectiveRedirectUri {
    if (kIsWeb) return '${Uri.base.origin}/callback.html';
    if (_useLoopback) return _loopbackRedirect;
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
        'scope': _requestedScopes.join(' '),
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
        // Pins the flow to the account we built the scope list for. Without it a
        // re-auth can land on a different account in the browser's session — and
        // if that one is a personal @gmail.com, the Workspace room scope it was
        // never meant to see comes with it and Google answers `invalid_scope`.
        if (accountEmail != null && accountEmail!.isNotEmpty)
          'login_hint': accountEmail!,
      },
    );

    final String resultUrl;
    if (kIsWeb) {
      resultUrl = await authenticateWeb(authUri.toString());
    } else {
      final String callbackScheme = _useLoopback
          ? _loopbackRedirect
          : Uri.parse(redirectUri).scheme;
      final FlutterWebAuth2Options authOptions = _useLoopback
          ? const FlutterWebAuth2Options(useWebview: false)
          : const FlutterWebAuth2Options(preferEphemeral: true);

      assert(() {
        // ignore: avoid_print
        print('[GmailAuth] loopback=$_useLoopback '
            'redirectUri=$_effectiveRedirectUri callbackScheme=$callbackScheme');
        // ignore: avoid_print
        print('[GmailAuth] opening: $authUri');
        return true;
      }());

      try {
        resultUrl = await FlutterWebAuth2.authenticate(
          url: authUri.toString(),
          callbackUrlScheme: callbackScheme,
          options: authOptions,
        );
        assert(() {
          // ignore: avoid_print
          print('[GmailAuth] callback received: $resultUrl');
          return true;
        }());
      } catch (e) {
        assert(() {
          // ignore: avoid_print
          print('[GmailAuth] authenticate failed: $e');
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
