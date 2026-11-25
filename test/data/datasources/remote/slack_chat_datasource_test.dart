import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/slack_chat_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/infrastructure/slack/slack_workspaces.dart';

import '../../../fakes/memory_secure_storage.dart';

/// Slack's Web API as the user of one workspace: conversations mapped onto
/// chats, mrkdwn into the renderer's HTML, DMs found without being opened,
/// and a refused token flagging the workspace rather than an email account.
void main() {
  late List<RequestOptions> requests;
  late Map<String, Object? Function(RequestOptions)> routes;
  late MemorySecureStorage storage;
  late SlackWorkspaces workspaces;

  Dio stub() => Dio(BaseOptions(baseUrl: SlackWorkspaces.apiBase))
    ..httpClientAdapter = _StubAdapter((o) async {
      requests.add(o);
      final method = o.uri.pathSegments.last;
      final handler = routes[method];
      final body = handler == null
          ? {'ok': false, 'error': 'unknown_method'}
          : handler(o);
      return ResponseBody.fromString(jsonEncode(body), 200, headers: _json);
    });

  SlackChatDatasource datasource() =>
      SlackChatDatasource(workspaces: workspaces, teamId: 'T1', dio: stub());

  Future<void> connected({bool needsReconnect = false}) =>
      storage.write(
          key: 'slack_workspaces',
          value: jsonEncode([
            SlackWorkspace(
              teamId: 'T1',
              teamName: 'Acme',
              userId: 'UME',
              clientId: '1.2',
              accessToken: 'xoxp-1',
              needsReconnect: needsReconnect,
            ).toJson(),
          ]));

  Map<String, dynamic> user(String id, String name, {String? email}) => {
        'ok': true,
        'user': {
          'id': id,
          'name': name.toLowerCase(),
          'profile': {
            'display_name': name,
            'email': ?email,
            'image_72': 'https://avatars.slack-edge.com/$id.png',
          },
        },
      };

  setUp(() async {
    requests = [];
    routes = {};
    storage = MemorySecureStorage();
    workspaces = SlackWorkspaces(storage: storage);
    SlackChatDatasource.forgetAll();
    await connected();
  });

  test('conversations map to chats, groups and threaded channels', () async {
    routes['users.conversations'] = (_) => {
          'ok': true,
          'channels': [
            {'id': 'D1', 'is_im': true, 'user': 'UANN'},
            {'id': 'G1', 'is_mpim': true, 'name': 'mpdm-me--ann--bob-1'},
            {'id': 'C1', 'is_channel': true, 'name': 'general'},
          ],
        };
    routes['users.info'] = (o) => switch (o.queryParameters['user']) {
          'UANN' => user('UANN', 'Ann'),
          _ => user('UME', 'me'),
        };
    final list = await datasource().listChats();
    expect(list.map((c) => (c.id, c.kind, c.title)), [
      ('D1', ChatKind.oneOnOne, 'Ann'),
      ('G1', ChatKind.group, 'ann, bob'),
      ('C1', ChatKind.space, '#general'),
    ]);
    expect(list.last.hasThreads, isTrue);
    expect(requests.first.headers['Authorization'], 'Bearer xoxp-1');
  });

  test('a message names its sender and keeps its thread count', () async {
    routes['conversations.history'] = (_) => {
          'ok': true,
          'messages': [
            {
              'ts': '1700000000.000200',
              'user': 'UANN',
              'text': 'Hi <@UME>, see <https://x.test/a?b=1&amp;c=2|the doc>',
              'reply_count': 3,
              'reactions': [
                {'name': '+1', 'count': 2},
                {'name': 'thumbsup::skin-tone-2', 'count': 1},
              ],
            },
            {'ts': '1700000000.000100', 'subtype': 'channel_join', 'text': 'x'},
          ],
          'has_more': true,
          'response_metadata': {'next_cursor': 'abc'},
        };
    routes['users.info'] = (o) => switch (o.queryParameters['user']) {
          'UANN' => user('UANN', 'Ann'),
          _ => user('UME', 'Me'),
        };
    final page = await datasource().messages(const ChatConversation(
        id: 'C1', kind: ChatKind.space, title: '#general', threaded: true));
    final m = page.messages.first;
    expect(m.senderName, 'Ann');
    expect(m.senderUserId, 'UANN');
    expect(m.replyCount, 3);
    expect(m.reactions, const [
      ChatReaction(emoji: '👍', count: 2),
      ChatReaction(emoji: '👍🏻', count: 1),
    ]);
    expect(m.bodyHtml, contains('<b>@Me</b>'));
    expect(m.bodyHtml,
        contains('<a href="https://x.test/a?b=1&amp;c=2">the doc</a>'));
    expect(page.messages.last.isSystem, isTrue);
    expect(page.nextLink, 'abc');
  });

  group('mrkdwn', () {
    String html(String s) => SlackChatDatasource.mrkdwnToHtml(s);

    test('formatting, quotes and code', () {
      expect(html('*bold* _it_ ~gone~ `x`'),
          '<b>bold</b> <i>it</i> <s>gone</s> <code>x</code>');
      expect(html('&gt; quoted\nnext'),
          '<blockquote>quoted</blockquote><br>next');
      expect(html('```a *b*\nc```'), contains('<pre>'));
    });

    test('channels, broadcasts and bare links', () {
      expect(html('<#C1|general> <!here>'), '<b>#general</b> <b>@here</b>');
      expect(html('<mailto:a@b.test|a@b.test>'),
          '<a href="mailto:a@b.test">a@b.test</a>');
      expect(html('<javascript:alert(1)|x>'), 'x',
          reason: 'only http(s) and mailto become links');
    });

    test('every standard shortcode is an emoji, skin tones joined', () {
      expect(html(':smile: :tada::tada: :pinched_fingers:'), '😄 🎉🎉 🤌');
      expect(html(':wave::skin-tone-3:'), '👋🏼');
      expect(html(':woman-raising-hand::skin-tone-3:'),
          '\u{1F64B}\u{1F3FC}\u{200D}\u{2640}\u{FE0F}',
          reason: 'in a joined emoji the tone follows the person');
      expect(html(':partyparrot:'), ':partyparrot:',
          reason: 'a workspace\'s own emoji is not a character');
    });

    test('shortcodes are left alone in code, words and times', () {
      expect(html('`:x:` and ```:x:```'),
          '<code>:x:</code> and <pre>:x:</pre>');
      expect(html('a:b:c at 10:30:00'), 'a:b:c at 10:30:00');
      expect(html('<https://x.test/a:b:c|:b: link>'),
          '<a href="https://x.test/a:b:c">:b: link</a>',
          reason: 'a link is not reformatted, its target least of all');
    });

    test('Slack\'s own escapes survive as text', () {
      expect(html('a &lt;b&gt; &amp; c'), 'a &lt;b&gt; &amp; c');
    });

    test('sent text is escaped as Slack expects', () {
      expect(SlackChatDatasource.escapeText('a<b>&c'), 'a&lt;b&gt;&amp;c');
    });
  });

  group('custom emoji', () {
    const general = ChatConversation(
        id: 'C1', kind: ChatKind.space, title: '#general', threaded: true);

    void history(Map<String, dynamic> message) {
      routes['conversations.history'] =
          (_) => {'ok': true, 'messages': [message]};
      routes['users.info'] = (_) => user('UANN', 'Ann');
    }

    test('a workspace\'s own emoji is its picture, aliases followed',
        () async {
      routes['emoji.list'] = (_) => {
            'ok': true,
            'emoji': {
              'party_parrot': 'https://emoji.slack-edge.com/T1/party_parrot/a_b.gif',
              'pp': 'alias:party_parrot',
              'yes': 'alias:white_check_mark',
            },
          };
      history({
        'ts': '1.1',
        'user': 'UANN',
        'text': ':party_parrot: :pp: :yes: _done_',
        'reactions': [
          {'name': 'pp', 'count': 3},
        ],
      });
      final m = (await datasource().messages(general)).messages.single;
      const img = '<img data-emoji="1" '
          'src="https://emoji.slack-edge.com/T1/party_parrot/a_b.gif"';
      expect(m.bodyHtml, startsWith('$img alt=":party_parrot:"> '
          '$img alt=":pp:"> ✅ <i>done</i>'),
          reason: 'the underscores in its URL are not italics');
      expect(m.reactions.single.imageUrl,
          'https://emoji.slack-edge.com/T1/party_parrot/a_b.gif');
      expect(m.reactions.single.count, 3);
    });

    test('a token without emoji:read keeps working, without them', () async {
      routes['emoji.list'] = (_) => {'ok': false, 'error': 'missing_scope'};
      history({'ts': '1.1', 'user': 'UANN', 'text': ':party_parrot:'});
      final m = (await datasource().messages(general)).messages.single;
      expect(m.bodyHtml, ':party_parrot:');
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse,
          reason: 'custom emoji are an extra, not a reason to reconnect');
    });

    test('the list is read once, not per page', () async {
      routes['emoji.list'] = (_) => {'ok': true, 'emoji': {}};
      history({'ts': '1.1', 'user': 'UANN', 'text': 'hi'});
      await datasource().messages(general);
      await datasource().messages(general);
      expect(
          requests.where((r) => r.uri.pathSegments.last == 'emoji.list'),
          hasLength(1));
    });
  });

  group('changes since', () {
    const dm = ChatConversation(id: 'D1', kind: ChatKind.oneOnOne, title: 'Ann');

    test('asks from the watermark and returns the newest ts as the next',
        () async {
      routes['conversations.history'] = (o) {
        expect(o.queryParameters['oldest'], '1700000000.000100');
        return {
          'ok': true,
          'messages': [
            {'ts': '1700000000.000300', 'user': 'UANN', 'text': 'new :wave:'},
          ],
          'has_more': false,
        };
      };
      routes['users.info'] = (_) => user('UANN', 'Ann');
      final d = await datasource().messagesSince(
          dm, DateTime.fromMicrosecondsSinceEpoch(1700000000000100));
      expect(d!.messages.single.bodyHtml, 'new 👋');
      expect(d.watermark, DateTime.fromMicrosecondsSinceEpoch(1700000000000300));
      expect(d.complete, isFalse, reason: 'edits and reactions do not show');
    });

    test('more than a page since is not a delta', () async {
      routes['conversations.history'] =
          (_) => {'ok': true, 'messages': [], 'has_more': true};
      expect(await datasource().messagesSince(dm, DateTime(2026)), isNull);
    });
  });

  test('a DM is found by address but never opened', () async {
    routes['users.lookupByEmail'] = (_) => user('UANN', 'Ann');
    routes['users.conversations'] = (_) => {
          'ok': true,
          'channels': [
            {'id': 'D1', 'is_im': true, 'user': 'UANN'},
          ],
        };
    final found = await datasource().findOneOnOne('ann@acme.test');
    expect(found?.id, 'D1');
    expect(found?.title, 'Ann');
    expect(requests.map((r) => r.uri.pathSegments.last),
        isNot(contains('conversations.open')));
  });

  test('someone Slack does not know is not reachable, and is asked once',
      () async {
    routes['users.lookupByEmail'] = (o) =>
        o.queryParameters['email'] == 'ann@acme.test'
            ? user('UANN', 'Ann')
            : {'ok': false, 'error': 'users_not_found'};
    final ds = datasource();
    expect(await ds.directoryMembers(['ann@acme.test', 'eve@other.test']),
        {'ann@acme.test'});
    await ds.directoryMembers(['eve@other.test']);
    expect(
        requests
            .where((r) => r.queryParameters['email'] == 'eve@other.test')
            .length,
        1);
  });

  test('a DM is unread when Slack counts it; a channel is never asked',
      () async {
    routes['users.conversations'] = (o) {
      expect(o.queryParameters['types'], 'mpim,im');
      return {
        'ok': true,
        'channels': [
          {'id': 'D1', 'is_im': true, 'user': 'UANN'},
          {'id': 'D2', 'is_im': true, 'user': 'UBOB'},
        ],
      };
    };
    routes['conversations.info'] = (o) => {
          'ok': true,
          'channel': {
            'id': o.queryParameters['channel'],
            'is_im': true,
            'latest': {'ts': '1700000000.000100', 'user': 'UANN'},
            'unread_count_display': o.queryParameters['channel'] == 'D1' ? 2 : 0,
          },
        };
    final recent = await datasource().listRecentChats();
    expect({for (final c in recent) c.id: c.unread}, {'D1': true, 'D2': false});
  });

  test('a refused token flags the workspace, as a ServerException', () async {
    routes['users.conversations'] = (_) => {'ok': false, 'error': 'token_revoked'};
    await expectLater(datasource().listChats(),
        throwsA(isA<SlackReconnectException>()));
    expect((await workspaces.byTeam('T1'))!.needsReconnect, isTrue);
    expect(SlackReconnectException('x'), isA<ServerException>());
    expect(SlackReconnectException('x'), isNot(isA<AuthException>()),
        reason: 'an AuthException means "re-auth this email account"');
  });

  test('a file image is fetched with the token, nothing else is', () async {
    final ds = datasource();
    expect(await ds.image('http://files.slack.com/x.png'), isNull,
        reason: 'https only');
  });

  test('sends to the thread a reply belongs to', () async {
    routes['chat.postMessage'] = (o) {
      final form = o.data as Map;
      expect(form['thread_ts'], '100.1');
      expect(form['text'], 'a &lt; b');
      return {
        'ok': true,
        'ts': '200.2',
        'message': {'ts': '200.2', 'user': 'UME', 'text': 'a &lt; b'},
      };
    };
    routes['users.info'] = (_) => user('UME', 'Me');
    final sent = await datasource().send(
      const ChatConversation(id: 'C1', kind: ChatKind.space, title: '#g'),
      'a < b',
      replyTo: ChatMessage(
        id: '100.1',
        createdAt: DateTime(2026),
        senderName: 'Ann',
        bodyHtml: '',
      ),
    );
    expect(sent.id, '200.2');
  });
}

const _json = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

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
