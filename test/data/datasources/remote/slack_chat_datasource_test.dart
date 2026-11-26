import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/text/emoji.dart';
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

  Future<void> connected(
          {bool needsReconnect = false, Set<String>? scopes}) =>
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
              scopes: scopes,
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
              'latest_reply': '1700000600.000300',
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
    expect(m.latestReplyAt?.millisecondsSinceEpoch, 1700000600000);
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

  group('an app\'s message', () {
    test('shows its attachment\'s blocks, not just the headline', () {
      // The shape of a CrowdStrike Falcon workflow alert.
      final html = SlackChatDatasource.messageHtml({
        'text': 'Falcon Alert: Detection',
        'attachments': [
          {
            'fallback': 'Falcon Alert: Detection',
            'blocks': [
              {
                'type': 'section',
                'text': {'type': 'mrkdwn', 'text': '*Trigger*'},
              },
              {
                'type': 'rich_text',
                'elements': [
                  {
                    'type': 'rich_text_list',
                    'style': 'bullet',
                    'elements': [
                      {
                        'type': 'rich_text_section',
                        'elements': [
                          {
                            'type': 'text',
                            'text': 'Detection name:',
                            'style': {'bold': true},
                          },
                          {'type': 'text', 'text': ' DLP: File Upload <x>'},
                        ],
                      },
                      {
                        'type': 'rich_text_section',
                        'elements': [
                          {'type': 'text', 'text': 'Source event URL: '},
                          {'type': 'link', 'url': 'https://falcon.test/d?a=1&b=2'},
                        ],
                      },
                    ],
                  },
                ],
              },
              {
                'type': 'actions',
                'elements': [
                  {
                    'type': 'button',
                    'text': {'type': 'plain_text', 'text': 'See in Falcon'},
                    'url': 'https://falcon.test/d',
                  },
                  {
                    'type': 'button',
                    'text': {'type': 'plain_text', 'text': 'Ack'},
                  },
                ],
              },
              {
                'type': 'context',
                'elements': [
                  {
                    'type': 'mrkdwn',
                    'text': 'Your <https://falcon.test/w|workflow> generated '
                        'this message.',
                  },
                ],
              },
            ],
          },
        ],
      });
      expect(html, contains('Falcon Alert: Detection'));
      expect(html, contains('<b>Trigger</b>'));
      expect(html,
          contains('<li><b>Detection name:</b> DLP: File Upload &lt;x&gt;</li>'));
      expect(
          html,
          contains('<a href="https://falcon.test/d?a=1&amp;b=2">'
              'https://falcon.test/d?a=1&amp;b=2</a>'));
      expect(html, contains('<a href="https://falcon.test/d">See in Falcon</a>'));
      expect(html, isNot(contains('Ack')));
      expect(html, contains('<a href="https://falcon.test/w">workflow</a>'));
    });

    test('layout blocks replace the fallback text; a person\'s rich_text '
        'block does not', () {
      final laidOut = SlackChatDatasource.messageHtml({
        'text': 'fallback only',
        'blocks': [
          {
            'type': 'header',
            'text': {'type': 'plain_text', 'text': 'Deploy & done'},
          },
          {
            'type': 'section',
            'fields': [
              {'type': 'mrkdwn', 'text': '*Env:* prod'},
              {'type': 'mrkdwn', 'text': '*By:* Ann'},
            ],
          },
        ],
      });
      expect(laidOut, isNot(contains('fallback only')));
      expect(laidOut, contains('<b>Deploy &amp; done</b>'));
      expect(laidOut, contains('<b>Env:</b> prod<br><b>By:</b> Ann'));

      final person = SlackChatDatasource.messageHtml({
        'text': 'hi *there*',
        'blocks': [
          {
            'type': 'rich_text',
            'elements': [
              {
                'type': 'rich_text_section',
                'elements': [
                  {'type': 'text', 'text': 'hi '},
                  {'type': 'text', 'text': 'there', 'style': {'bold': true}},
                ],
              },
            ],
          },
        ],
      });
      expect(person, 'hi <b>there</b>');
    });

    test('a classic attachment shows its title, text and fields', () {
      final html = SlackChatDatasource.messageHtml({
        'text': '',
        'attachments': [
          {
            'fallback': 'Build failed',
            'title': 'Build #12',
            'title_link': 'https://ci.test/12',
            'text': 'failed on `main`',
            'fields': [
              {'title': 'Branch', 'value': 'main'},
            ],
          },
        ],
      });
      expect(html, contains('<a href="https://ci.test/12">Build #12</a>'));
      expect(html, contains('failed on <code>main</code>'));
      expect(html, contains('<b>Branch</b>: main'));
      expect(html, isNot(contains('Build failed')));
    });
  });

  group('GIFs', () {
    test('a /giphy post shows its image block, sized; the logo is left out',
        () {
      // The shape of a /giphy message, as Slack's API returns it.
      final html = SlackChatDatasource.messageHtml({
        'text': '',
        'blocks': [
          {
            'type': 'image',
            'image_url':
                'https://media2.giphy.com/media/K5/giphy.gif?cid=6&rid=giphy.gif',
            'alt_text': 'red eyes',
            'image_width': 480,
            'image_height': 270,
            'title': {'type': 'plain_text', 'text': 'red eyes'},
          },
          {
            'type': 'context',
            'elements': [
              {
                'type': 'image',
                'image_url':
                    'https://a.slack-edge.com/img/plugins/giphy/service_32.png',
                'alt_text': 'giphy logo',
              },
              {
                'type': 'mrkdwn',
                'text': 'Posted using /giphy',
              },
            ],
          },
        ],
      });
      expect(
          html,
          contains('<img src="https://media2.giphy.com/media/K5/giphy.gif'
              '?cid=6&amp;rid=giphy.gif" alt="red eyes" width="480" '
              'height="270">'));
      expect(html, contains('Posted using /giphy'));
      expect(html, isNot(contains('service_32')));
    });

    test('an unfurled GIF link shows the picture it unfurled to', () {
      final html = SlackChatDatasource.messageHtml({
        'text': '<https://giphy.com/gifs/x>',
        'attachments': [
          {
            'fallback': 'GIPHY: party',
            'image_url': 'https://media.giphy.com/media/x/giphy.gif',
            'image_width': 200,
            'image_height': 100,
          },
        ],
      });
      expect(
          html,
          contains('<img src="https://media.giphy.com/media/x/giphy.gif" '
              'alt="GIPHY: party" width="200" height="100">'));
    });

    test('a picture that is not https is not shown', () {
      final html = SlackChatDatasource.messageHtml({
        'text': '',
        'blocks': [
          {'type': 'image', 'image_url': 'http://x.test/a.gif', 'alt_text': 'a'},
        ],
      });
      expect(html, isNot(contains('<img')));
    });

    test('an uploaded GIF shows a rendition that moves', () async {
      routes['conversations.history'] = (_) => {
            'ok': true,
            'messages': [
              {
                'ts': '1700000000.000300',
                'user': 'UANN',
                'text': '',
                'files': [
                  {
                    'name': 'dance.gif',
                    'mimetype': 'image/gif',
                    'thumb_720': 'https://files.slack.com/still.png',
                    'thumb_480_gif': 'https://files.slack.com/moving.gif',
                    'url_private': 'https://files.slack.com/dance.gif',
                  },
                  {
                    'name': 'chart.png',
                    'mimetype': 'image/png',
                    'thumb_720': 'https://files.slack.com/chart_720.png',
                    'url_private': 'https://files.slack.com/chart.png',
                  },
                ],
              },
            ],
          };
      routes['users.info'] = (_) => user('UANN', 'Ann');
      final page = await datasource().messages(const ChatConversation(
          id: 'C1', kind: ChatKind.space, title: '#general', threaded: true));
      final body = page.messages.single.bodyHtml;
      expect(body, contains('src="https://files.slack.com/moving.gif"'));
      expect(body, isNot(contains('still.png')));
      expect(body, contains('src="https://files.slack.com/chart_720.png"'));
      expect(page.messages.single.attachmentNames, isEmpty);
    });
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
      expect(html('my devbox:laughing: ok:+1::skin-tone-2:'),
          'my devbox😆 ok👍🏻',
          reason: 'Slack shows a name glued to a word as the emoji');
      expect(html('x:smile:y 1:smile:'), 'x:smile:y 1:smile:');
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

  test('a DM is unread when Slack counts it', () async {
    routes['users.conversations'] = (o) {
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

  test('a DM Slack counts unread is checked against last_read: an AI app\'s '
      'assistant thread is not unread', () async {
    routes['users.conversations'] = (_) => {
          'ok': true,
          'channels': [
            {'id': 'DROVO', 'is_im': true, 'user': 'UROVO'},
            {'id': 'DANN', 'is_im': true, 'user': 'UANN'},
            {'id': 'DBOB', 'is_im': true, 'user': 'UBOB'},
          ],
        };
    routes['conversations.info'] = (o) => {
          'ok': true,
          'channel': {
            'id': o.queryParameters['channel'],
            'is_im': true,
            'last_read': '1700000100.000000',
            'unread_count_display': o.queryParameters['channel'] == 'DBOB' ? 0 : 1,
          },
        };
    final history = <String>[];
    routes['conversations.history'] = (o) {
      final id = o.queryParameters['channel'] as String;
      history.add(id);
      return {
        'ok': true,
        'messages': [
          if (id == 'DROVO')
            {
              'ts': '1700000200.000000',
              'user': 'UROVO',
              'bot_id': 'B1',
              'subtype': 'assistant_app_thread',
            }
          else
            {'ts': '1700000200.000000', 'user': 'UANN'},
        ],
      };
    };
    final recent = await datasource().listRecentChats();
    expect({for (final c in recent) c.id: c.unread},
        {'DROVO': false, 'DANN': true, 'DBOB': false});
    expect(history, isNot(contains('DBOB')),
        reason: 'a DM Slack calls read costs no history call');
  });

  test('a channel is unread when someone — or a bot — wrote after last_read, '
      'not for a join', () async {
    routes['users.conversations'] = (o) {
      expect(o.queryParameters['types'], contains('public_channel'));
      return {
        'ok': true,
        'channels': [
          {'id': 'C1', 'is_channel': true, 'name': 'secops'},
          {'id': 'C2', 'is_channel': true, 'name': 'random'},
          {'id': 'C3', 'is_channel': true, 'name': 'quiet'},
        ],
      };
    };
    routes['conversations.info'] = (o) => {
          'ok': true,
          'channel': {
            'id': o.queryParameters['channel'],
            'is_channel': true,
            'last_read': '1700000100.000000',
          },
        };
    routes['conversations.history'] = (o) {
      expect(o.queryParameters.containsKey('oldest'), isFalse,
          reason: 'the newest are read either way, for activity');
      return {
        'ok': true,
        'messages': switch (o.queryParameters['channel']) {
          'C1' => [
              {'ts': '1700000200.000000', 'bot_id': 'B1', 'subtype': 'bot_message'},
            ],
          'C2' => [
              {'ts': '1700000200.000000', 'user': 'UANN', 'subtype': 'channel_join'},
            ],
          _ => [
              {'ts': '1700000090.000000', 'user': 'UANN'},
            ],
        },
      };
    };
    final recent = await datasource().listRecentChats();
    expect({for (final c in recent) c.id: c.unread},
        {'C1': true, 'C2': false, 'C3': false});
    expect(recent.firstWhere((c) => c.id == 'C3').lastActivity, isNotNull,
        reason: 'a read channel\'s activity is learned too');
  });

  group('a reply in a thread', () {
    // Every channel's newest post (a parent) is older than last_read; only
    // its thread moved.
    late Map<String, Map<String, dynamic>> parents;
    late Map<String, List<Map<String, dynamic>>> replies;
    late List<String> repliesAsked;

    setUp(() {
      repliesAsked = [];
      routes['users.conversations'] = (_) => {
            'ok': true,
            'channels': [
              for (final id in parents.keys)
                {'id': id, 'is_channel': true, 'name': id.toLowerCase()},
            ],
          };
      routes['conversations.info'] = (o) => {
            'ok': true,
            'channel': {
              'id': o.queryParameters['channel'],
              'is_channel': true,
              'last_read': '1700000100.000000',
            },
          };
      routes['conversations.history'] = (o) => {
            'ok': true,
            'messages': [parents[o.queryParameters['channel']]],
          };
      routes['conversations.replies'] = (o) {
        final id = o.queryParameters['channel'] as String;
        repliesAsked.add(id);
        expect(o.queryParameters['oldest'], '1700000100.000000');
        return {
          'ok': true,
          'messages': [parents[id], ...?replies[id]],
        };
      };
    });

    Map<String, dynamic> parent(String latestReply,
            {List<String> users = const ['UANN'], String? lastRead}) =>
        {
          'ts': '1700000050.000000',
          'thread_ts': '1700000050.000000',
          'user': 'UBOB',
          'reply_count': 3,
          'latest_reply': latestReply,
          'reply_users': users,
          'last_read': ?lastRead,
        };

    Map<String, dynamic> reply(String ts, String user, {String? subtype}) => {
          'ts': ts,
          'thread_ts': '1700000050.000000',
          'user': user,
          'subtype': ?subtype,
        };

    test('by someone else lights the channel; the user\'s own, a thread read '
        'in Slack, or one before last_read do not', () async {
      parents = {
        'CNEW': parent('1700000200.000000'),
        'COWN': parent('1700000200.000000', users: ['UME']),
        'CMINE': parent('1700000300.000000', users: ['UANN', 'UME']),
        'CREAD': parent('1700000200.000000', lastRead: '1700000200.000000'),
        'COLD': parent('1700000090.000000'),
        'CJOIN': parent('1700000200.000000'),
      };
      replies = {
        'CNEW': [reply('1700000200.000000', 'UANN')],
        'CMINE': [
          reply('1700000090.000000', 'UANN'),
          reply('1700000300.000000', 'UME'),
        ],
        'CREAD': [reply('1700000200.000000', 'UANN')],
        'CJOIN': [
          reply('1700000200.000000', 'UANN', subtype: 'channel_join'),
        ],
      };
      final recent = await datasource().listRecentChats();
      expect({for (final c in recent) c.id: c.unread}, {
        'CNEW': true,
        'COWN': false,
        'CMINE': false,
        'CREAD': false,
        'COLD': false,
        'CJOIN': false,
      });
      expect(repliesAsked, isNot(contains('COWN')),
          reason: 'only the user replied: no call');
      expect(repliesAsked, isNot(contains('COLD')),
          reason: 'nothing past last_read: no call');
      expect(recent.firstWhere((c) => c.id == 'CNEW').lastActivity,
          DateTime.fromMicrosecondsSinceEpoch(1700000200000000),
          reason: 'the reply is the activity, past any mark made here');
    });

    test('marking the channel read marks past its newest reply', () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      parents = {'CNEW': parent('1700000200.000000')};
      replies = {
        'CNEW': [reply('1700000200.000000', 'UANN')],
      };
      final ds = datasource();
      final chat = (await ds.listRecentChats()).single;
      expect(chat.unread, isTrue);
      final marked = <String>[];
      routes['conversations.mark'] = (o) {
        marked.add((o.data as Map)['ts'] as String);
        return {'ok': true};
      };
      await ds.markRead(chat);
      expect(marked, ['1700000200.000000']);
    });
  });

  test('every channel is reached in turn, however many', () async {
    routes['users.conversations'] = (_) => {
          'ok': true,
          'channels': [
            for (var i = 0; i < 30; i++)
              {'id': 'C$i', 'is_channel': true, 'name': 'c$i'},
          ],
        };
    routes['conversations.info'] = (o) => {
          'ok': true,
          'channel': {'id': o.queryParameters['channel'], 'last_read': '1.0'},
        };
    routes['conversations.history'] = (o) => {
          'ok': true,
          'messages': [
            {'ts': '${o.queryParameters['channel']!.substring(1)}.5'},
          ],
        };
    final ds = datasource();
    final asked = <String>{};
    for (var poll = 0; poll < 8; poll++) {
      requests.clear();
      await ds.listRecentChats();
      final infos = requests
          .where((r) => r.uri.pathSegments.last == 'conversations.info');
      expect(infos.length, lessThanOrEqualTo(8));
      asked.addAll(infos.map((r) => r.queryParameters['channel'] as String));
    }
    expect(asked, hasLength(30));
  });

  test('unread channels the poll passes by stay unread; one read elsewhere '
      'clears at its next check', () async {
    routes['users.conversations'] = (_) => {
          'ok': true,
          'channels': [
            for (var i = 0; i < 30; i++)
              {'id': 'C$i', 'is_channel': true, 'name': 'c$i'},
          ],
        };
    // More unread than a poll's four re-check slots.
    final unreadIds = {'C0', 'C1', 'C2', 'C3', 'C4', 'C5'};
    final asked = <String>{};
    routes['conversations.info'] = (o) {
      final id = o.queryParameters['channel'] as String;
      asked.add(id);
      return {
        'ok': true,
        'channel': {
          'id': id,
          'last_read': unreadIds.contains(id) ? '1.0' : '99.0',
        },
      };
    };
    routes['conversations.history'] = (o) => {
          'ok': true,
          'messages': [
            {'ts': '2.${o.queryParameters['channel']!.substring(1)}',
              'user': 'UANN'},
          ],
        };
    final ds = datasource();
    Future<Set<String>> unread() async => {
          for (final c in await ds.listRecentChats())
            if (c.unread) c.id,
        };
    expect(await unread(), unreadIds);
    for (var poll = 0; poll < 3; poll++) {
      asked.clear();
      expect(await unread(), unreadIds);
      expect(asked.containsAll(unreadIds), isFalse,
          reason: 'some were passed by, and kept their answer');
    }
    unreadIds.remove('C0');
    expect(await unread(), unreadIds,
        reason: 'one last found unread is asked about first');
  });

  group('marking a channel read', () {
    const channel =
        ChatConversation(id: 'C1', kind: ChatKind.space, title: '#g');

    setUp(() {
      routes['conversations.history'] = (_) => {
            'ok': true,
            'messages': [
              {'ts': '200.0', 'user': 'UANN'},
            ],
          };
    });

    test('is skipped for a workspace connected without channels:write',
        () async {
      await datasource().markRead(channel);
      expect(requests, isEmpty);
    });

    test('marks the newest message once the scopes are granted', () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      routes['conversations.mark'] = (o) {
        expect((o.data as Map)['ts'], '200.0');
        return {'ok': true};
      };
      await datasource().markRead(channel);
      expect(requests.map((r) => r.uri.pathSegments.last),
          contains('conversations.mark'));
    });

    test('a refusal for a missing scope does not ask to reconnect',
        () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      routes['conversations.mark'] =
          (_) => {'ok': false, 'error': 'missing_scope'};
      await expectLater(datasource().markRead(channel), throwsA(anything));
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });
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

  group('editing', () {
    test('a typed message comes back as typed, bare links and escapes undone',
        () {
      expect(
          SlackChatDatasource.editableTextOf({
            'text': 'a &lt; b &amp; see <https://x.test/a?b=1&amp;c=2> or '
                '<mailto:ann@x.test|ann@x.test>',
          }),
          'a < b & see https://x.test/a?b=1&c=2 or ann@x.test');
    });

    test('a mention, labelled link, file or layout is not offered', () {
      String? of(Map<String, dynamic> m) =>
          SlackChatDatasource.editableTextOf(m);
      expect(of({'text': 'hi <@U1>'}), isNull);
      expect(of({'text': 'see <https://x.test|the doc>'}), isNull);
      expect(of({'text': '<!here> lunch'}), isNull);
      expect(
          of({
            'text': 'pic',
            'files': [
              {'id': 'F1'},
            ],
          }),
          isNull);
      expect(
          of({
            'text': 'x',
            'blocks': [
              {'type': 'section'},
            ],
          }),
          isNull);
      expect(of({'text': ''}), isNull);
    });

    test('chat.update sends the escaped text and keeps what it does not echo',
        () async {
      routes['chat.update'] = (o) {
        final form = o.data as Map;
        expect(form['channel'], 'D1');
        expect(form['ts'], '100.1');
        expect(form['text'], 'a &lt; b');
        return {
          'ok': true,
          'ts': '100.1',
          'text': 'a &lt; b',
          'message': {
            'text': 'a &lt; b',
            'edited': {'user': 'UME', 'ts': '1700000100.000000'},
          },
        };
      };
      final edited = await datasource().edit(
        const ChatConversation(id: 'D1', kind: ChatKind.oneOnOne, title: 'A'),
        ChatMessage(
          id: '100.1',
          createdAt: DateTime(2026),
          senderName: 'Me',
          senderUserId: 'UME',
          bodyHtml: 'a',
          editableText: 'a',
          reactions: const [ChatReaction(emoji: '👍', count: 1)],
        ),
        'a < b',
      );
      expect(edited.bodyHtml, 'a &lt; b');
      expect(edited.editableText, 'a < b');
      expect(edited.editedAt, isNotNull);
      expect(edited.reactions, const [ChatReaction(emoji: '👍', count: 1)]);
    });
  });

  group('renaming', () {
    const channel = ChatConversation(
        id: 'C1', kind: ChatKind.space, title: '#general', threaded: true);

    test('only channels; DMs and group DMs have no name', () {
      final ds = datasource();
      expect(ds.canRename(channel), isTrue);
      expect(
          ds.canRename(const ChatConversation(
              id: 'D1', kind: ChatKind.oneOnOne, title: 'Ann')),
          isFalse);
      expect(
          ds.canRename(const ChatConversation(
              id: 'G1', kind: ChatKind.group, title: 'ann, bob')),
          isFalse);
    });

    test('the name is sent as Slack takes it and comes back with its #',
        () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      routes['conversations.rename'] = (o) {
        final form = o.data as Map;
        expect(form['channel'], 'C1');
        expect(form['name'], 'team-updates');
        return {
          'ok': true,
          'channel': {'id': 'C1', 'name': 'team-updates'},
        };
      };
      final renamed = await datasource().rename(channel, ' #Team  Updates ');
      expect(renamed.title, '#team-updates');
      expect(renamed.key, channel.key);
      expect(renamed.threaded, isTrue);
    });

    test('a workspace without channels:write is asked to reconnect, not '
        'flagged', () async {
      await expectLater(
        datasource().rename(channel, 'x'),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('Connect this Slack'))),
      );
      expect(requests, isEmpty);
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });

    test('missing_scope from the rename itself does not flag the workspace',
        () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      routes['conversations.rename'] =
          (_) => {'ok': false, 'error': 'missing_scope'};
      await expectLater(
        datasource().rename(channel, 'x'),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('Connect this Slack'))),
      );
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });

    test('a refusal is worded', () async {
      await connected(scopes: const {'channels:write', 'groups:write'});
      routes['conversations.rename'] =
          (_) => {'ok': false, 'error': 'name_taken'};
      await expectLater(
        datasource().rename(channel, 'random'),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('already has that name'))),
      );
      routes['conversations.rename'] =
          (_) => {'ok': false, 'error': 'not_authorized'};
      await expectLater(
        datasource().rename(channel, 'random'),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('channel\'s managers'))),
      );
    });
  });

  group('reactions', () {
    const general = ChatConversation(
        id: 'C1', kind: ChatKind.space, title: '#general', threaded: true);
    final message = ChatMessage(
      id: '1700000000.000200',
      createdAt: DateTime(2026),
      senderName: 'Ann',
      senderUserId: 'UANN',
      bodyHtml: 'hi',
    );

    test('every reaction the menu offers has a Slack name', () {
      for (final e in quickReactions) {
        expect(SlackChatDatasource.slackReactionName(e), isNotNull,
            reason: e);
      }
      expect(SlackChatDatasource.slackReactionName('❤'), 'heart');
      expect(SlackChatDatasource.slackReactionName('❤️'), 'heart');
      expect(SlackChatDatasource.slackReactionName('👍🏽'), '+1::skin-tone-4');
      expect(SlackChatDatasource.slackReactionName(':party_parrot:'),
          'party_parrot');
    });

    test('reactions.add names the emoji and the message', () async {
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['reactions.add'] = (o) {
        expect(o.data, {
          'channel': 'C1',
          'timestamp': '1700000000.000200',
          'name': '+1',
        });
        return {'ok': true};
      };
      expect(await datasource().react(general, message, '👍'), isTrue);
    });

    test('already_reacted is the user\'s reaction already there', () async {
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['reactions.add'] = (_) => {'ok': false, 'error': 'already_reacted'};
      expect(await datasource().react(general, message, '👍'), isFalse);
    });

    test('a workspace without reactions:write is asked to connect again, '
        'not flagged', () async {
      await connected(scopes: const {'chat:write'});
      await expectLater(
          datasource().react(general, message, '👍'),
          throwsA(isA<ServerException>().having(
              (e) => e.message, 'message', contains('Connect this Slack'))));
      expect(requests, isEmpty);

      // Granted as far as NightMail knew, refused by Slack.
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['reactions.add'] = (_) => {'ok': false, 'error': 'missing_scope'};
      await expectLater(datasource().react(general, message, '👍'),
          throwsA(isA<ServerException>()));
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });

    test('a reaction keeps who gave it', () async {
      routes['conversations.history'] = (_) => {
            'ok': true,
            'messages': [
              {
                'ts': '1.1',
                'user': 'UANN',
                'text': 'hi',
                'reactions': [
                  {
                    'name': 'tada',
                    'count': 2,
                    'users': ['UME', 'UANN'],
                  },
                ],
              },
            ],
          };
      routes['users.info'] = (_) => user('UANN', 'Ann');
      final m = (await datasource().messages(general)).messages.single;
      expect(m.reactions.single,
          const ChatReaction(emoji: '🎉', count: 2, userIds: ['UME', 'UANN']));
    });

    test('reactions.remove takes it off; no_reaction is it already gone',
        () async {
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['reactions.remove'] = (o) {
        expect(o.data, {
          'channel': 'C1',
          'timestamp': '1700000000.000200',
          'name': 'heart',
        });
        return {'ok': true};
      };
      expect(await datasource().unreact(general, message, '❤️'), isTrue);
      routes['reactions.remove'] = (_) => {'ok': false, 'error': 'no_reaction'};
      expect(await datasource().unreact(general, message, '❤️'), isFalse);
      routes['reactions.remove'] = (_) => {'ok': false, 'error': 'missing_scope'};
      await expectLater(datasource().unreact(general, message, '❤️'),
          throwsA(isA<ServerException>()));
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });
  });

  group('sending a picture', () {
    const dm = ChatConversation(id: 'D1', kind: ChatKind.oneOnOne, title: 'Ann');
    final image = ChatOutgoingImage(
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
      name: 'image.png',
    );
    late List<Duration> waits;

    setUp(() {
      waits = SlackChatDatasource.uploadWaits;
      SlackChatDatasource.uploadWaits = const [Duration.zero, Duration.zero];
    });
    tearDown(() => SlackChatDatasource.uploadWaits = waits);

    Map<String, dynamic> shared(String ts) => {
          'ts': ts,
          'user': 'UME',
          'text': 'look',
          'files': [
            {
              'id': 'F1',
              'name': 'image.png',
              'mimetype': 'image/png',
              'url_private': 'https://files.slack.com/files-pri/T1-F1/image.png',
            },
          ],
        };

    test('uploads it, completes it into the DM with the text, and returns '
        'the message Slack posted', () async {
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['users.info'] = (_) => user('UME', 'Me');
      routes['files.getUploadURLExternal'] = (o) {
        expect(o.data, {'filename': 'image.png', 'length': '3'});
        return {
          'ok': true,
          'upload_url': 'https://files.slack.com/upload/v1/ABC',
          'file_id': 'F1',
        };
      };
      routes['ABC'] = (o) {
        expect(o.data, [1, 2, 3]);
        expect(o.headers['Authorization'], isNull,
            reason: 'the URL is the credential');
        return 'OK - 3';
      };
      routes['files.completeUploadExternal'] = (o) {
        expect(o.data, {
          'files': jsonEncode([
            {'id': 'F1', 'title': 'image.png'},
          ]),
          'channel_id': 'D1',
          'initial_comment': 'look &lt;here&gt;',
        });
        return {'ok': true, 'files': [{'id': 'F1'}]};
      };
      var looks = 0;
      routes['conversations.history'] = (_) => {
            'ok': true,
            'messages': [
              if (++looks > 1) shared('1700000000.000900'),
              {'ts': '1700000000.000100', 'user': 'UANN', 'text': 'older'},
            ],
          };
      final sent =
          await datasource().send(dm, 'look <here>', image: image);
      expect(sent.id, '1700000000.000900');
      expect(sent.bodyHtml, contains('<img src="https://files.slack.com/'));
      expect(looks, 2, reason: 'looked again until it appeared');
    });

    test('a reply goes into the thread', () async {
      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['users.info'] = (_) => user('UME', 'Me');
      routes['files.getUploadURLExternal'] = (_) => {
            'ok': true,
            'upload_url': 'https://files.slack.com/upload/v1/ABC',
            'file_id': 'F1',
          };
      routes['ABC'] = (_) => 'OK';
      routes['files.completeUploadExternal'] = (o) {
        expect((o.data as Map)['thread_ts'], '1700000000.000100');
        expect((o.data as Map).containsKey('initial_comment'), isFalse);
        return {'ok': true};
      };
      routes['conversations.replies'] = (_) => {
            'ok': true,
            'messages': [
              {'ts': '1700000000.000100', 'user': 'UANN', 'text': 'post'},
              shared('1700000000.000900')
                ..['thread_ts'] = '1700000000.000100',
            ],
          };
      final post = ChatMessage(
        id: '1700000000.000100',
        createdAt: DateTime(2026),
        senderName: 'Ann',
        bodyHtml: 'post',
      );
      final sent = await datasource().send(dm, '', replyTo: post, image: image);
      expect(sent.id, '1700000000.000900');
    });

    test('a workspace without files:write is asked to connect again, '
        'not flagged', () async {
      await connected(scopes: const {'chat:write'});
      await expectLater(
          datasource().send(dm, '', image: image),
          throwsA(isA<ServerException>().having(
              (e) => e.message, 'message', contains('send pictures'))));
      expect(requests, isEmpty);

      await connected(scopes: SlackWorkspaces.userScopes.toSet());
      routes['files.getUploadURLExternal'] =
          (_) => {'ok': false, 'error': 'missing_scope'};
      await expectLater(datasource().send(dm, '', image: image),
          throwsA(isA<ServerException>()));
      expect((await workspaces.byTeam('T1'))!.needsReconnect, isFalse);
    });
  });

  test('a DM and a group DM thread as channels do', () {
    final ds = datasource();
    for (final kind in ChatKind.values) {
      expect(ds.canThread(ChatConversation(id: 'D1', kind: kind, title: 'x')),
          isTrue, reason: '$kind');
    }
  });

  group('mentions', () {
    test('a tag goes as <@U…>, the rest escaped as ever', () {
      expect(
          SlackChatDatasource.outgoingText('@Ann & <co> @Ann', const [
            ChatMember(displayName: 'Ann', userId: 'UANN'),
          ]),
          '<@UANN> &amp; &lt;co&gt; <@UANN>');
    });

    test('the conversation\'s members, named by users.info', () async {
      await connected();
      routes['conversations.members'] = (o) {
        expect(o.queryParameters['channel'], 'C9');
        return {
          'ok': true,
          'members': ['UME', 'UZED'],
          'response_metadata': {'next_cursor': ''},
        };
      };
      routes['users.info'] = (o) => switch (o.queryParameters['user']) {
            'UZED' => user('UZED', 'Zed', email: 'zed@x.com'),
            _ => user('UME', 'Me'),
          };
      final members = await datasource().mentionable(
          const ChatConversation(id: 'C9', kind: ChatKind.space, title: '#g'));
      expect(members.map((m) => (m.userId, m.displayName)),
          containsAll([('UZED', 'Zed'), ('UME', 'Me')]));
    });
  });

  group('huddles', () {
    const ann = ChatMember(displayName: 'Ann', userId: 'UANN');

    test('in the DM with them, its own huddle link', () async {
      final ds = datasource();
      expect(ds.calling, ChatCalling.huddle);
      final link = await ds.callLink(
          const ChatConversation(
              id: 'D9',
              kind: ChatKind.oneOnOne,
              title: 'Ann',
              members: [ann]),
          ann,
          video: false);
      expect(link, 'https://app.slack.com/huddle/T1/D9');
      expect(requests, isEmpty);
    });

    test('from a channel, the listed DM with them', () async {
      routes['users.conversations'] = (_) => {
            'ok': true,
            'channels': [
              {'id': 'D1', 'is_im': true, 'user': 'UANN'},
            ],
          };
      final link = await datasource().callLink(
          const ChatConversation(
              id: 'C1', kind: ChatKind.channel, title: 'general'),
          ann,
          video: true);
      expect(link, 'https://app.slack.com/huddle/T1/D1');
      expect(requests.map((r) => r.uri.pathSegments.last),
          isNot(contains('conversations.open')));
    });

    test('with no DM yet, opens one', () async {
      routes['users.conversations'] = (_) => {'ok': true, 'channels': []};
      routes['conversations.open'] = (o) {
        expect((o.data as Map)['users'], 'UANN');
        return {
          'ok': true,
          'channel': {'id': 'D7'},
        };
      };
      final link = await datasource().callLink(
          const ChatConversation(
              id: 'C1', kind: ChatKind.channel, title: 'general'),
          ann,
          video: false);
      expect(link, 'https://app.slack.com/huddle/T1/D7');
    });
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
