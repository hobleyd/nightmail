import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/error/exceptions.dart';
import '../auth/loopback_auth_flow.dart';
import '../auth/oauth_state.dart';

/// One connected Slack workspace and the user token NightMail chats with.
///
/// [clientId] is the Slack app that issued the token: each workspace runs its
/// own internal app (see `tool/setup_slack_app.sh`), and a refresh must name
/// the app the refresh token came from.
class SlackWorkspace {
  const SlackWorkspace({
    required this.teamId,
    required this.teamName,
    required this.userId,
    required this.clientId,
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.needsReconnect = false,
    this.scopes,
  });

  final String teamId;
  final String teamName;

  /// The signed-in user's Slack id (`U…`), what a message's `user` names.
  final String userId;
  final String clientId;
  final String accessToken;

  /// Only for a rotating token; a non-rotating `xoxp-` token never expires.
  final String? refreshToken;
  final DateTime? expiresAt;

  /// Slack refused the token (revoked, expired refresh token, app removed):
  /// the workspace stays listed, asking to be connected again.
  final bool needsReconnect;

  /// The user scopes Slack granted, as `oauth.v2.access` reported them; null
  /// for a workspace connected before they were recorded.
  final Set<String>? scopes;

  /// Granted everything this version asks for — false means connecting
  /// again adds something (custom emoji: `emoji:read`). Unknown is false.
  bool get hasAllScopes =>
      scopes != null && SlackWorkspaces.userScopes.every(scopes!.contains);

  /// The chat id the repository and the UI know this workspace by.
  String get chatId => '$chatIdPrefix$teamId';

  static const chatIdPrefix = 'slack:';

  /// The team id in a [chatId], or null for an email account's id.
  static String? teamIdOf(String chatId) =>
      chatId.startsWith(chatIdPrefix) ? chatId.substring(chatIdPrefix.length) : null;

  SlackWorkspace copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    bool? needsReconnect,
  }) =>
      SlackWorkspace(
        teamId: teamId,
        teamName: teamName,
        userId: userId,
        clientId: clientId,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        expiresAt: expiresAt ?? this.expiresAt,
        needsReconnect: needsReconnect ?? this.needsReconnect,
        scopes: scopes,
      );

  Map<String, dynamic> toJson() => {
        'teamId': teamId,
        'teamName': teamName,
        'userId': userId,
        'clientId': clientId,
        'accessToken': accessToken,
        'refreshToken': ?refreshToken,
        'expiresAt': ?expiresAt?.toUtc().toIso8601String(),
        'needsReconnect': needsReconnect,
        'scopes': ?scopes?.toList(),
      };

  static SlackWorkspace? fromJson(Object? json) {
    if (json is! Map) return null;
    final teamId = json['teamId'], token = json['accessToken'];
    if (teamId is! String || token is! String) return null;
    return SlackWorkspace(
      teamId: teamId,
      teamName: json['teamName'] as String? ?? 'Slack',
      userId: json['userId'] as String? ?? '',
      clientId: json['clientId'] as String? ?? '',
      accessToken: token,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
      needsReconnect: json['needsReconnect'] == true,
      scopes: (json['scopes'] as List?)?.whereType<String>().toSet(),
    );
  }
}

/// The connected Slack workspaces, kept in the Keychain (secure storage) as
/// one JSON list — shared by every window, since each is its own isolate.
///
/// Nothing is cached in memory: the chat window and the main window both
/// call Slack, and a rotating refresh token is single-use, so whichever
/// window refreshes first writes the new pair and the other must read it
/// rather than spend the old one ([accessToken]).
///
/// Slack's failures never touch the email accounts: a refused token marks
/// the workspace [SlackWorkspace.needsReconnect], nothing more.
class SlackWorkspaces {
  SlackWorkspaces({
    required this._storage,
    Dio? dio,
    this._loopback = const LoopbackAuthFlow(),
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: apiBase,
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
            ));

  final FlutterSecureStorage _storage;
  final Dio _dio;
  final LoopbackAuthFlow _loopback;

  static const apiBase = 'https://slack.com/api';
  static const _storageKey = 'slack_workspaces';

  /// Separate from Gmail's 34572 so the two sign-ins never take each other's
  /// port over. `localhost`, as Slack's PKCE guide names it: with PKCE on,
  /// Slack treats a localhost redirect as a desktop one.
  static const loopbackPort = 34573;
  static const loopbackRedirect = 'http://localhost:$loopbackPort/slack';

  /// iOS and Android, through the `nightmail` scheme Microsoft sign-in
  /// already registers. Slack always issues rotating tokens to a custom
  /// scheme.
  static const mobileRedirect = 'nightmail://slack-callback';

  /// User scopes, each for a method `SlackChatDatasource` calls:
  /// `users.conversations`/`conversations.info` (`*:read`),
  /// `conversations.history`/`replies` (`*:history`), `users.info`
  /// (`users:read`), `users.lookupByEmail` (`users:read.email`),
  /// `chat.postMessage` (`chat:write`), `conversations.open` and
  /// `conversations.mark` on direct messages (`im:write`, `mpim:write` —
  /// channels are never marked, so no `channels:write`), `url_private` images
  /// (`files:read`), `search.messages` (`search:read`) and the workspace's own
  /// emoji, `emoji.list` (`emoji:read`).
  static const userScopes = [
    'channels:read',
    'groups:read',
    'im:read',
    'mpim:read',
    'channels:history',
    'groups:history',
    'im:history',
    'mpim:history',
    'users:read',
    'users:read.email',
    'chat:write',
    'im:write',
    'mpim:write',
    'files:read',
    'search:read',
    'emoji:read',
  ];

  final _changes = StreamController<void>.broadcast();

  /// Fires when a workspace is connected, reconnected, removed or flagged in
  /// this isolate. Another window's changes are seen on its next read.
  Stream<void> get changes => _changes.stream;

  Future<List<SlackWorkspace>> all() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final w in list) ?SlackWorkspace.fromJson(w)];
    } catch (e) {
      debugPrint('[Slack] workspaces unreadable: $e');
      return const [];
    }
  }

  Future<SlackWorkspace?> byTeam(String teamId) async =>
      (await all()).where((w) => w.teamId == teamId).firstOrNull;

  Future<void> _put(SlackWorkspace workspace) async {
    final list = [
      for (final w in await all())
        if (w.teamId != workspace.teamId) w,
      workspace,
    ];
    await _write(list);
  }

  Future<void> _write(List<SlackWorkspace> list) async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode([for (final w in list) w.toJson()]),
    );
    _changes.add(null);
  }

  /// Forgets [teamId] and asks Slack to revoke its token (best effort).
  Future<void> remove(String teamId) async {
    final list = await all();
    final gone = list.where((w) => w.teamId == teamId).firstOrNull;
    await _write([
      for (final w in list)
        if (w.teamId != teamId) w,
    ]);
    if (gone == null) return;
    try {
      await _dio.get<Object>('/auth.revoke',
          options: Options(
              headers: {'Authorization': 'Bearer ${gone.accessToken}'}));
    } catch (_) {}
  }

  /// Marks [teamId] as needing to be connected again.
  Future<void> flagReconnect(String teamId) async {
    final w = await byTeam(teamId);
    if (w == null || w.needsReconnect) return;
    debugPrint('[Slack] ${w.teamName} needs reconnecting');
    await _put(w.copyWith(needsReconnect: true));
  }

  /// A usable token for [teamId], refreshed first when it is about to
  /// expire. Throws [SlackReconnectException] when Slack has refused it.
  Future<String> accessToken(String teamId) async {
    final w = await byTeam(teamId);
    if (w == null || w.needsReconnect) {
      throw SlackReconnectException(w?.teamName ?? 'Slack');
    }
    final expires = w.expiresAt;
    final refresh = w.refreshToken;
    if (expires == null ||
        refresh == null ||
        DateTime.now().isBefore(expires.subtract(const Duration(minutes: 5)))) {
      return w.accessToken;
    }
    return _refresh(w);
  }

  Future<String> _refresh(SlackWorkspace w) async {
    final Map<String, dynamic> data;
    try {
      data = await _form('/oauth.v2.access', {
        'grant_type': 'refresh_token',
        'refresh_token': w.refreshToken!,
        'client_id': w.clientId,
      });
    } on SlackApiException catch (e) {
      // Single-use refresh tokens: another window may have spent this one
      // a moment ago and stored the pair it got back.
      final now = await byTeam(w.teamId);
      if (now != null &&
          !now.needsReconnect &&
          now.refreshToken != w.refreshToken) {
        return now.accessToken;
      }
      debugPrint('[Slack] refresh refused: ${e.error}');
      await flagReconnect(w.teamId);
      throw SlackReconnectException(w.teamName);
    }
    final token = _tokenOf(data);
    if (token == null) {
      await flagReconnect(w.teamId);
      throw SlackReconnectException(w.teamName);
    }
    await _put(w.copyWith(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: token.expiresAt,
      needsReconnect: false,
    ));
    return token.accessToken;
  }

  /// Signs in to a workspace through Slack's OAuth v2 with PKCE, as the user
  /// (user scopes only — a desktop redirect may not ask for bot scopes), and
  /// stores it. Connecting a workspace already listed replaces its token,
  /// which is how a [SlackWorkspace.needsReconnect] one is mended.
  Future<SlackWorkspace> connect({required String clientId}) async {
    final id = clientId.trim();
    if (id.isEmpty) {
      throw const AuthException(message: 'Enter the Slack app\'s Client ID.');
    }
    final verifier = _codeVerifier();
    final state = generateOAuthState();
    final redirect = _isMobile ? mobileRedirect : loopbackRedirect;
    final authUri = Uri.parse('https://slack.com/oauth/v2/authorize').replace(
      queryParameters: {
        'client_id': id,
        'user_scope': userScopes.join(','),
        'redirect_uri': redirect,
        'state': state,
        'code_challenge': _codeChallenge(verifier),
        'code_challenge_method': 'S256',
      },
    );

    final String result;
    if (_isMobile) {
      result = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: 'nightmail',
        options: const FlutterWebAuth2Options(preferEphemeral: false),
      );
    } else {
      result = await _loopback.authenticate(
        authorizationUrl: authUri,
        port: loopbackPort,
        expectedState: state,
      );
    }
    final back = Uri.parse(result);
    final error = back.queryParameters['error'];
    if (error != null) {
      throw AuthException(
          message: error == 'access_denied'
              ? 'Slack sign-in was cancelled.'
              : 'Slack refused the sign-in ($error).');
    }
    verifyOAuthState(expected: state, redirect: back);
    final code = back.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const AuthException(message: 'Slack sent no authorization code.');
    }

    final Map<String, dynamic> data;
    try {
      data = await _form('/oauth.v2.access', {
        'client_id': id,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
      });
    } on SlackApiException catch (e) {
      throw AuthException(message: 'Slack refused the sign-in (${e.error}).');
    }
    final token = _tokenOf(data);
    final team = data['team'];
    final user = data['authed_user'];
    if (token == null || team is! Map || user is! Map) {
      throw const AuthException(message: 'Slack returned no user token.');
    }
    final workspace = SlackWorkspace(
      teamId: team['id'] as String,
      teamName: (team['name'] as String?)?.trim().isNotEmpty == true
          ? team['name'] as String
          : 'Slack',
      userId: user['id'] as String? ?? '',
      clientId: id,
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: token.expiresAt,
      scopes: (user['scope'] as String?)
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet(),
    );
    await _put(workspace);
    return workspace;
  }

  /// The user token in an `oauth.v2.access` answer: under `authed_user` for a
  /// code exchange, at the top for a refresh of a user token.
  static ({String accessToken, String? refreshToken, DateTime? expiresAt})?
      _tokenOf(Map<String, dynamic> data) {
    final user = data['authed_user'];
    final src = user is Map && user['access_token'] is String
        ? user
        : (data['token_type'] == 'user' || data['access_token'] is String)
            ? data
            : null;
    if (src == null) return null;
    final access = src['access_token'];
    if (access is! String || access.isEmpty) return null;
    final expiresIn = src['expires_in'];
    return (
      accessToken: access,
      refreshToken: src['refresh_token'] as String?,
      expiresAt: expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
    );
  }

  Future<Map<String, dynamic>> _form(
      String path, Map<String, String> fields) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        path,
        data: fields,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = r.data ?? const {};
      if (data['ok'] != true) {
        throw SlackApiException(data['error'] as String? ?? 'unknown_error');
      }
      return data;
    } on DioException catch (e) {
      throw NetworkException(message: e.message ?? 'Network error');
    }
  }

  static bool get _isMobile =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static String _codeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(96, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// RFC 4648 §5 base64url of the verifier's SHA-256, unpadded.
  static String _codeChallenge(String verifier) => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');
}

/// Slack answered `ok: false`. [error] is its code (`invalid_auth`,
/// `channel_not_found`, `ratelimited`, …).
class SlackApiException implements Exception {
  const SlackApiException(this.error, {this.retryAfter});
  final String error;
  final Duration? retryAfter;

  @override
  String toString() => 'SlackApiException: $error';
}

/// The workspace's token was refused and it must be connected again from
/// Settings > General (or the chat's Reconnect button). A [ServerException],
/// not an [AuthException]: the latter means "this email account needs
/// re-auth" everywhere else in the app.
class SlackReconnectException extends ServerException {
  SlackReconnectException(String teamName)
      : super(
            message: '$teamName needs reconnecting: Slack no longer accepts '
                'NightMail\'s sign-in.',
            statusCode: 401);
}
