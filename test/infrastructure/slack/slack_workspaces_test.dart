import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/chat_remote_datasource.dart';
import 'package:nightmail/data/repositories/chat_repository_impl.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/slack/slack_workspaces.dart';

import '../../fakes/memory_secure_storage.dart';
import '../../fakes/memory_chat_local_datasource.dart';

/// Connected Slack workspaces: kept in the Keychain for every window,
/// refreshed when a rotating token is about to expire — without losing to
/// the other window spending the same single-use refresh token — and offered
/// as chat systems beside the account's own.
void main() {
  late MemorySecureStorage storage;
  late List<Map<String, dynamic>> answers;
  late List<RequestOptions> requests;

  SlackWorkspaces store() => SlackWorkspaces(
        storage: storage,
        dio: Dio(BaseOptions(baseUrl: SlackWorkspaces.apiBase))
          ..httpClientAdapter = _StubAdapter((o) async {
            requests.add(o);
            return ResponseBody.fromString(
                jsonEncode(answers.removeAt(0)), 200,
                headers: {
                  Headers.contentTypeHeader: [Headers.jsonContentType],
                });
          }),
      );

  SlackWorkspace workspace({
    String token = 'xoxe.xoxp-old',
    String? refresh = 'xoxe-1-old',
    DateTime? expiresAt,
  }) =>
      SlackWorkspace(
        teamId: 'T1',
        teamName: 'Acme',
        userId: 'UME',
        clientId: '1.2',
        accessToken: token,
        refreshToken: refresh,
        expiresAt: expiresAt,
      );

  Future<void> save(SlackWorkspace w) => storage.write(
      key: 'slack_workspaces', value: jsonEncode([w.toJson()]));

  setUp(() {
    storage = MemorySecureStorage();
    answers = [];
    requests = [];
  });

  test('a token that does not expire is used as stored', () async {
    await save(workspace(refresh: null));
    expect(await store().accessToken('T1'), 'xoxe.xoxp-old');
    expect(requests, isEmpty);
  });

  test('a token about to expire is refreshed and the new pair stored',
      () async {
    await save(workspace(
        expiresAt: DateTime.now().add(const Duration(minutes: 1))));
    answers.add({
      'ok': true,
      'token_type': 'user',
      'access_token': 'xoxe.xoxp-new',
      'refresh_token': 'xoxe-1-new',
      'expires_in': 43200,
    });
    final s = store();
    expect(await s.accessToken('T1'), 'xoxe.xoxp-new');
    final form = requests.single.data as Map;
    expect(form['grant_type'], 'refresh_token');
    expect(form['client_id'], '1.2', reason: 'the app that issued it');
    expect(form.containsKey('client_secret'), isFalse, reason: 'PKCE');
    expect((await s.byTeam('T1'))!.refreshToken, 'xoxe-1-new');
  });

  test('a refresh token the other window already spent uses its new pair',
      () async {
    await save(workspace(
        expiresAt: DateTime.now().add(const Duration(minutes: 1))));
    final s = store();
    // The chat window refreshes first and stores what it got back…
    answers.add({'ok': false, 'error': 'invalid_refresh_token'});
    final refreshing = s.accessToken('T1');
    await save(workspace(
      token: 'xoxe.xoxp-theirs',
      refresh: 'xoxe-1-theirs',
      expiresAt: DateTime.now().add(const Duration(hours: 12)),
    ));
    // …so this one's refusal is not a reason to reconnect.
    expect(await refreshing, 'xoxe.xoxp-theirs');
    expect((await s.byTeam('T1'))!.needsReconnect, isFalse);
  });

  test('a refused refresh with nothing newer stored needs reconnecting',
      () async {
    await save(workspace(
        expiresAt: DateTime.now().add(const Duration(minutes: 1))));
    answers.add({'ok': false, 'error': 'invalid_refresh_token'});
    final s = store();
    await expectLater(
        s.accessToken('T1'), throwsA(isA<SlackReconnectException>()));
    expect((await s.byTeam('T1'))!.needsReconnect, isTrue);
  });

  group('as chat systems', () {
    final imap = ImapAccount(
      id: 'imap',
      displayName: 'Home',
      emailAddress: 'me@home.test',
      host: 'imap.home.test',
      port: 993,
      useSsl: true,
      smtpHost: 'smtp.home.test',
      smtpPort: 465,
      smtpUseSsl: true,
    );
    final work = MicrosoftAccount(
      id: 'work',
      displayName: 'Work',
      emailAddress: 'me@contoso.com',
      tenantId: 't',
    );

    ChatRepository repo(Account account) => ChatRepositoryImpl(
          accountManager: _Accounts(account),
          contacts: _NoContacts(),
          slack: store(),
          local: MemoryChatLocalDatasource(),
        );

    test('the account\'s own chat comes first, then Slack', () async {
      await save(workspace(refresh: null));
      final sources = await repo(work).sources('work');
      expect(sources.map((s) => (s.id, s.label)), [
        ('work', 'Teams'),
        ('slack:T1', 'Slack · Acme'),
      ]);
    });

    test('a workspace without every scope asked for offers a reconnect',
        () async {
      await save(workspace(refresh: null));
      expect((await repo(work).sources('work')).last.missingScopes, isTrue,
          reason: 'connected before scopes were recorded');
      final full = SlackWorkspace(
        teamId: 'T1',
        teamName: 'Acme',
        userId: 'UME',
        clientId: '1.2',
        accessToken: 'xoxp-1',
        scopes: SlackWorkspaces.userScopes.toSet(),
      );
      await storage.write(
          key: 'slack_workspaces', value: jsonEncode([full.toJson()]));
      expect((await repo(work).sources('work')).last.missingScopes, isFalse);
      expect(SlackWorkspace.fromJson(full.toJson())!.hasAllScopes, isTrue,
          reason: 'stored with the workspace');
    });

    test('an IMAP account has Slack alone — no menu', () async {
      await save(workspace(refresh: null));
      final sources = await repo(imap).sources('imap');
      expect(sources.map((s) => s.id), ['slack:T1']);
    });

    test('without Slack, nothing changes', () async {
      expect((await repo(work).sources('work')).map((s) => s.id), ['work']);
      expect(await repo(imap).sources('imap'), isEmpty);
    });

    test('a workspace needing reconnection asks for consent', () async {
      await save(workspace(refresh: null));
      final r = repo(work);
      expect(await r.access('slack:T1'), ChatAccess.full);
      await store().flagReconnect('T1');
      expect(await r.access('slack:T1'), ChatAccess.needsConsent);
      expect(await r.access('slack:T9'), ChatAccess.unsupported);
    });
  });
}

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.account);

  final Account account;

  @override
  Account? accountById(String? id) => id == account.id ? account : null;

  @override
  Future<({bool chats, bool channels})?> chatGrants(String accountId) async =>
      account is MicrosoftAccount ? (chats: true, channels: false) : null;

  @override
  ChatRemoteDatasource? chatDatasourceForAccount(String accountId) => null;
}

class _NoContacts extends Fake implements ContactCacheRepository {}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions) _respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      _respond(options);

  @override
  void close({bool force = false}) {}
}
