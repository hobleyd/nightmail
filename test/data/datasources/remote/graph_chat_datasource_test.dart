import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_chat_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';

/// The chat datasource talks to Microsoft and to a NightMail Server with one
/// set of requests, so what it asks for is pinned to what both accept
/// (nightware ADR 0009): no `$filter`, newest-first ordering only, `$top` at
/// most 50, members bound by address on the account's own Graph root. The
/// one exception is Microsoft-only: a chat's changes since a time.
void main() {
  const root = 'https://mail.example.com/graph/v1.0';
  late List<RequestOptions> requests;
  late Map<String, Object? Function(RequestOptions)> routes;

  GraphChatDatasource datasource({bool server = true}) {
    final dio = Dio(BaseOptions(baseUrl: root))
      ..httpClientAdapter = _StubAdapter((o) async {
        requests.add(o);
        final handler = routes.entries
            .where((e) => o.uri.path.endsWith(e.key))
            .firstOrNull
            ?.value;
        if (handler == null) {
          return ResponseBody.fromString('{"error":{"message":"nope"}}', 404,
              headers: _json);
        }
        final body = handler(o);
        if (body is int) {
          return ResponseBody.fromString(
              '{"error":{"message":"status $body"}}', body,
              headers: _json);
        }
        return ResponseBody.fromString(jsonEncode(body), 200, headers: _json);
      });
    return GraphChatDatasource(
      dio: dio,
      ownAddresses: {'me@example.com'},
      isNightmailServer: server,
    );
  }

  setUp(() {
    requests = [];
    routes = {};
    GraphChatDatasource.forgetIdentities();
  });

  group('changes since', () {
    const chat =
        ChatConversation(id: '19:c', kind: ChatKind.oneOnOne, title: 'Ann');
    Map<String, dynamic> message(String id, String modified) => {
          'id': id,
          'messageType': 'message',
          'createdDateTime': '2026-11-25T09:00:00Z',
          'lastModifiedDateTime': modified,
          'from': {
            'user': {'id': 'u-ann', 'displayName': 'Ann'},
          },
          'body': {'contentType': 'text', 'content': 'hi'},
        };

    test('Microsoft filters on lastModifiedDateTime, ordered by it',
        () async {
      routes['/chats/19:c/messages'] = (o) {
        expect(o.queryParameters[r'$orderby'], 'lastModifiedDateTime desc');
        expect(
            o.queryParameters[r'$filter'],
            startsWith('lastModifiedDateTime gt 2026-11-25T09:00:00.000Z and '
                'lastModifiedDateTime lt '));
        return {
          'value': [
            message('1', '2026-11-25T09:05:00Z'),
            message('2', '2026-11-25T09:07:00Z'),
          ],
        };
      };
      final d = await datasource(server: false)
          .messagesSince(chat, DateTime.utc(2026, 11, 25, 9));
      expect(d!.messages.map((m) => m.id), ['1', '2']);
      expect(d.watermark, DateTime.utc(2026, 11, 25, 9, 7));
      expect(d.complete, isTrue, reason: 'edits and reactions move it too');
    });

    test('a NightMail Server is never sent a filter', () async {
      expect(
          await datasource().messagesSince(chat, DateTime.utc(2026)), isNull);
      expect(requests, isEmpty);
    });

    test('too many pages of changes is not a delta', () async {
      routes['/chats/19:c/messages'] = (_) => {
            'value': [message('1', '2026-11-25T09:05:00Z')],
            '@odata.nextLink': '$root/chats/19:c/messages?\$skiptoken=x',
          };
      expect(
          await datasource(server: false)
              .messagesSince(chat, DateTime.utc(2026)),
          isNull);
      expect(requests, hasLength(4));
    });
  });

  group('unread', () {
    Map<String, dynamic> chat({
      String sender = 'u-ann',
      String sent = '2026-11-25T10:00:00Z',
      String? read = '2026-11-25T09:00:00Z',
      bool hidden = false,
      String type = 'message',
    }) =>
        {
          'id': '19:c',
          'chatType': 'oneOnOne',
          'viewpoint': {'isHidden': hidden, 'lastMessageReadDateTime': read},
          'lastMessagePreview': {
            'createdDateTime': sent,
            'messageType': type,
            'from': {
              'user': {'id': sender, 'displayName': 'X'},
            },
            'body': {'contentType': 'text', 'content': 'hi'},
          },
        };

    test('someone else wrote after the read marker', () {
      expect(GraphChatDatasource.isUnread(chat(), 'u-me'), isTrue);
      expect(GraphChatDatasource.isUnread(chat(read: null), 'u-me'), isTrue,
          reason: 'never read (Microsoft), or marker not on the newest '
              '(Nightware)');
    });

    test('read up to the newest, your own message, hidden, or an event', () {
      expect(
          GraphChatDatasource.isUnread(
              chat(read: '2026-11-25T10:00:00Z'), 'u-me'),
          isFalse,
          reason: 'equal times are read');
      expect(GraphChatDatasource.isUnread(chat(sender: 'u-me'), 'u-me'),
          isFalse);
      expect(GraphChatDatasource.isUnread(chat(hidden: true), 'u-me'), isFalse);
      expect(
          GraphChatDatasource.isUnread(
              chat(type: 'systemEventMessage'), 'u-me'),
          isFalse);
    });

    test('the poll is one page with the preview alone', () async {
      routes['/me'] = (_) => {'id': 'u-me'};
      routes['/me/chats'] = (_) => {
            'value': [chat(), {...chat(sender: 'u-me'), 'id': '19:d'}],
          };
      final chats = await datasource().listRecentChats();
      expect(chats.where((c) => c.unread).map((c) => c.id), ['19:c']);
      final listing =
          requests.where((r) => r.uri.path.endsWith('/me/chats')).single;
      expect(listing.uri.queryParameters[r'$expand'], 'lastMessagePreview');
      expect(listing.uri.queryParameters[r'$top'], '50');
    });

    test('a chat listed with no preview has never had a message', () async {
      routes['/me'] = (_) => {'id': 'u-me'};
      routes['/me/chats'] = (_) => {
            'value': [
              chat(),
              {
                'id': '19:empty',
                'chatType': 'meeting',
                'topic': 'Sync',
                'createdDateTime': '2026-11-24T00:00:00Z',
                'lastMessagePreview': null,
              },
            ],
          };
      final chats = await datasource().listRecentChats();
      expect({for (final c in chats) c.id: c.noMessages},
          {'19:c': false, '19:empty': true});
    });

    test('a one-on-one listed without members is named by its sender',
        () async {
      routes['/me'] = (_) => {'id': 'u-me'};
      routes['/me/chats'] = (_) => {
            'value': [chat(), {...chat(sender: 'u-me'), 'id': '19:d'}],
          };
      final chats = await datasource().listRecentChats();
      expect(chats.map((c) => c.title), ['X', 'Chat'],
          reason: 'never the user\'s own name');
    });

    test('two accounts on one root never share an id', () async {
      var answer = 'u-first';
      routes['/me'] = (_) => {'id': answer};
      final dio = Dio(BaseOptions(baseUrl: root))
        ..httpClientAdapter = _StubAdapter((o) async {
          requests.add(o);
          return ResponseBody.fromString(
              jsonEncode(routes['/me']!(o)), 200, headers: _json);
        });
      GraphChatDatasource as(String address) => GraphChatDatasource(
          dio: dio, ownAddresses: {address}, isNightmailServer: false);

      expect(await as('a@example.com').ownUserId(null), 'u-first');
      answer = 'u-second';
      expect(await as('b@example.com').ownUserId(null), 'u-second');
      expect(await as('a@example.com').ownUserId(null), 'u-first');
    });

    test('mark read: Nightware takes the id, Microsoft the tenant too',
        () async {
      routes['/me'] = (_) => {'id': 'u-me'};
      routes['/organization'] = (_) => {
            'value': [
              {'id': 'tenant-1'},
            ],
          };
      routes['/markChatReadForUser'] = (_) => <String, dynamic>{};
      const c = ChatConversation(id: '19:c', kind: ChatKind.group, title: 'G');

      await datasource().markRead(c);
      expect(requests.last.uri.path, endsWith('/chats/19:c/markChatReadForUser'));
      expect(requests.last.data, {
        'user': {'id': 'u-me'},
      });

      GraphChatDatasource.forgetIdentities();
      await datasource(server: false).markRead(c);
      expect(requests.last.data, {
        'user': {'id': 'u-me', 'tenantId': 'tenant-1'},
      });
    });
  });

  test('lists chats without \$filter, newest first, titled by the others', () async {
    routes['/me/chats'] = (_) => {
          'value': [
            {
              'id': '19:a',
              'chatType': 'oneOnOne',
              'topic': null,
              'lastUpdatedDateTime': '2026-11-20T00:00:00Z',
              'members': [
                {'displayName': 'Me', 'email': 'ME@example.com'},
                {'displayName': 'Bob', 'email': 'Bob@Example.com', 'userId': 'b'},
              ],
              'lastMessagePreview': {
                'createdDateTime': '2026-11-23T01:00:00Z',
                'body': {'contentType': 'html', 'content': '<p>Hi&nbsp;there</p>'},
              },
            },
            {
              'id': '19:g',
              'chatType': 'group',
              'topic': 'Launch',
              'members': [],
            },
          ],
        };
    final chats = await datasource().listChats();

    final q = requests.single.uri.queryParameters;
    expect(q.containsKey(r'$filter'), isFalse);
    expect(q[r'$orderby'], 'lastMessagePreview/createdDateTime desc');
    expect(int.parse(q[r'$top']!), lessThanOrEqualTo(50));

    expect(chats.first.kind, ChatKind.oneOnOne);
    expect(chats.first.title, 'Bob');
    expect(chats.first.members.single.email, 'bob@example.com');
    expect(chats.first.lastMessagePreview, 'Hi there');
    expect(chats.first.lastActivity,
        DateTime.parse('2026-11-23T01:00:00Z').toLocal());
    expect(chats[1].title, 'Launch');
  });

  test('never follows a nextLink to another host with the bearer token',
      () async {
    routes['/me/chats'] = (_) => {
          'value': <Object>[],
          '@odata.nextLink': 'https://evil.example.net/me/chats?page=2',
        };
    await datasource().listChats();
    expect(requests, hasLength(1));
  });

  test('Microsoft binds members by directory id, resolved by address',
      () async {
    Map<String, dynamic>? sent;
    routes['/me'] = (_) => {'id': 'me-id'};
    // bob's UPN is not his mail address: the UPN lookup misses, mail finds him.
    routes['/users/bob%40example.com'] = (_) => 404;
    routes['/users'] = (o) => {
          'value': [
            {'id': 'bob-id'}
          ],
        };
    routes['/chats'] = (o) {
      sent = o.data as Map<String, dynamic>;
      return {'id': '19:new', 'chatType': 'oneOnOne'};
    };
    await datasource(server: false).createOneOnOne(
      ownEmail: 'me@example.com',
      email: 'bob@example.com',
      displayName: 'Bob',
    );
    expect(
      [for (final m in sent!['members'] as List) m['user@odata.bind']],
      ["$root/users('me-id')", "$root/users('bob-id')"],
    );
    final byMail = requests.firstWhere((r) =>
        r.uri.path.endsWith('/users') &&
        (r.uri.queryParameters[r'$filter'] ?? '').startsWith('mail eq'));
    expect(byMail.uri.queryParameters[r'$filter'], "mail eq 'bob@example.com'");
  });

  test('Microsoft: an address nobody in the directory has is a 404',
      () async {
    routes['/me'] = (_) => {'id': 'me-id'};
    routes['/users'] = (_) => {'value': <Object>[]};
    await expectLater(
      datasource(server: false).createOneOnOne(
        ownEmail: 'me@example.com',
        email: 'stranger@other.example',
        displayName: 'Stranger',
      ),
      throwsA(isA<ServerException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('a Graph that refuses both expansions at once gets two listings',
      () async {
    routes['/me/chats'] = (o) {
      final expand = o.uri.queryParameters[r'$expand'];
      if (expand == 'members,lastMessagePreview') return 400;
      if (expand == 'members') {
        return {
          'value': [
            {
              'id': '19:a',
              'members': [
                {'displayName': 'Bob', 'email': 'bob@example.com'},
              ],
            },
          ],
        };
      }
      return {
        'value': [
          {
            'id': '19:a',
            'chatType': 'oneOnOne',
            'lastMessagePreview': {
              'createdDateTime': '2026-11-23T01:00:00Z',
              'body': {'contentType': 'text', 'content': 'hey'},
            },
          },
        ],
      };
    };
    final chats = await datasource(server: false).listChats();
    expect(chats.single.title, 'Bob');
    expect(chats.single.lastMessagePreview, 'hey');
  });

  test('a search hit names its sender by email address', () async {
    routes['/search/query'] = (o) {
      final request = ((o.data as Map)['requests'] as List).single as Map;
      expect(request['size'], lessThanOrEqualTo(25));
      return {
        'value': [
          {
            'hitsContainers': [
              {
                'hits': [
                  {
                    'summary': 'the <c0>launch</c0> plan',
                    'resource': {
                      'id': '1',
                      'createdDateTime': '2026-11-23T01:00:00Z',
                      'from': {
                        'emailAddress': {
                          'name': 'Bob',
                          'address': 'bob@example.com'
                        }
                      },
                      'channelIdentity': {},
                      'chatId': '19:a',
                    },
                  },
                ],
              },
            ],
          },
        ],
      };
    };
    final hits = await datasource(server: false).search('launch');
    expect(hits.single.message.senderName, 'Bob');
    expect(hits.single.message.bodyHtml, 'the launch plan');
    expect(hits.single.conversationKey, '19:a');
  });

  test('a NightMail Server binds members by address on its own root',
      () async {
    Map<String, dynamic>? sent;
    routes['/chats'] = (o) {
      sent = o.data as Map<String, dynamic>;
      return {'id': '19:new', 'chatType': 'oneOnOne'};
    };
    final chat = await datasource().createOneOnOne(
      ownEmail: 'me@example.com',
      email: 'bob@example.com',
      displayName: 'Bob',
    );
    final binds = [
      for (final m in sent!['members'] as List) m['user@odata.bind'] as String,
    ];
    expect(binds, [
      "$root/users('me%40example.com')",
      "$root/users('bob%40example.com')",
    ]);
    expect(sent!['chatType'], 'oneOnOne');
    expect(chat.id, '19:new');
    expect(chat.title, 'Bob');
  });

  test('channel posts carry their replies, oldest first', () async {
    routes['/messages'] = (_) => {
          'value': [
            {
              'id': '1',
              'createdDateTime': '2026-11-23T01:00:00Z',
              'subject': 'Plan',
              'from': {
                'user': {'displayName': 'Ann', 'id': 'a'}
              },
              'body': {'contentType': 'text', 'content': 'a < b\nc'},
              'replies': [
                {
                  'id': '3',
                  'createdDateTime': '2026-11-23T03:00:00Z',
                  'body': {'contentType': 'html', 'content': 'later'},
                },
                {
                  'id': '2',
                  'createdDateTime': '2026-11-23T02:00:00Z',
                  'body': {'contentType': 'html', 'content': 'first'},
                },
              ],
              'reactions': [
                {'reactionType': 'like'},
                {'reactionType': 'like'},
              ],
            },
          ],
        };
    final page = await datasource().messages(const ChatConversation(
      id: 'c',
      kind: ChatKind.channel,
      title: 'General',
      teamId: 't',
    ));
    expect(requests.single.uri.path, endsWith('/teams/t/channels/c/messages'));
    expect(requests.single.uri.queryParameters[r'$expand'], 'replies');
    final post = page.messages.single;
    expect(post.subject, 'Plan');
    expect(post.bodyHtml, 'a &lt; b<br>c');
    expect(post.replies.map((r) => r.id), ['2', '3']);
    expect(post.reactions.single, const ChatReaction(emoji: '👍', count: 2));
  });

  test('a reply in a channel goes to the post\'s replies', () async {
    routes['/replies'] = (_) => {
          'id': '9',
          'createdDateTime': '2026-11-23T01:00:00Z',
          'body': {'contentType': 'text', 'content': 'ok'},
        };
    await datasource().send(
      const ChatConversation(
          id: 'c', kind: ChatKind.channel, title: 'G', teamId: 't'),
      'ok',
      replyTo: ChatMessage(
          id: '1', createdAt: DateTime(2026), senderName: '', bodyHtml: ''),
    );
    expect(requests.single.uri.path,
        endsWith('/teams/t/channels/c/messages/1/replies'));
    expect((requests.single.data as Map)['body'],
        {'contentType': 'text', 'content': 'ok'});
  });

  test('a team the user cannot list does not hide the others', () async {
    routes['/me/joinedTeams'] = (_) => {
          'value': [
            {'id': 'locked', 'displayName': 'Locked'},
            {'id': 'open', 'displayName': 'Open'},
          ],
        };
    routes['/teams/locked/channels'] = (_) => 403;
    routes['/teams/open/channels'] = (_) => {
          'value': [
            {'id': 'c1', 'displayName': 'General'},
          ],
        };
    final channels = await datasource().listChannels();
    expect(channels.single.teamName, 'Open');
    expect(channels.single.key, 'open/c1');
  });

  test('a 401 surfaces as an AuthException', () async {
    routes['/me/chats'] = (_) => 401;
    expect(datasource().listChats(), throwsA(isA<AuthException>()));
  });

  group('renaming', () {
    const group =
        ChatConversation(id: '19:g', kind: ChatKind.group, title: 'Ann, Bob');
    const channel = ChatConversation(
        id: '19:ch', kind: ChatKind.channel, title: 'General', teamId: 'T');

    test('a group chat\'s topic, a server channel\'s name', () async {
      routes['/chats/19:g'] = (o) {
        expect(o.method, 'PATCH');
        expect(o.data, {'topic': 'Launch'});
        return <String, Object?>{};
      };
      routes['/teams/T/channels/19:ch'] = (o) {
        expect(o.method, 'PATCH');
        expect(o.data, {'displayName': 'Releases'});
        return <String, Object?>{};
      };
      final ds = datasource();
      expect((await ds.rename(group, 'Launch')).title, 'Launch');
      final renamed = await ds.rename(channel, 'Releases');
      expect(renamed.title, 'Releases');
      expect(renamed.key, channel.key);
      expect(requests.map((r) => r.uri.path.split('/v1.0').last),
          ['/chats/19:g', '/teams/T/channels/19:ch']);
    });

    test('never a one-on-one or meeting; a Microsoft 365 channel needs admin '
        'consent', () {
      const oneOnOne =
          ChatConversation(id: '19:c', kind: ChatKind.oneOnOne, title: 'A');
      const meeting =
          ChatConversation(id: '19:m', kind: ChatKind.meeting, title: 'M');
      for (final ds in [datasource(), datasource(server: false)]) {
        expect(ds.canRename(group), isTrue);
        expect(ds.canRename(oneOnOne), isFalse);
        expect(ds.canRename(meeting), isFalse);
      }
      expect(datasource().canRename(channel), isTrue);
      expect(datasource(server: false).canRename(channel), isFalse);
    });
  });

  group('sending a picture', () {
    final image = ChatOutgoingImage(
      bytes: Uint8List.fromList([1, 2, 3]),
      mimeType: 'image/png',
      name: 'shot.png',
      width: 1440,
      height: 900,
    );

    test('as hosted content the body refers to, drawn at a readable size',
        () {
      final body = GraphChatDatasource.imageMessageBody('a <b>\nc', image);
      expect(body['body'], {
        'contentType': 'html',
        'content': '<p>a &lt;b&gt;<br>c</p><p><img '
            'src="../hostedContents/1/\$value" alt="shot.png" width="360" '
            'height="225" style="vertical-align:bottom; width:360px; '
            'height:225px"></p>',
      });
      expect(body['hostedContents'], [
        {
          '@microsoft.graph.temporaryId': '1',
          'contentBytes': 'AQID',
          'contentType': 'image/png',
        },
      ]);
    });

    test('a picture alone has no caption', () {
      final body = GraphChatDatasource.imageMessageBody(
          ' ',
          ChatOutgoingImage(
              bytes: image.bytes, mimeType: 'image/png', name: 'x.png'));
      expect((body['body'] as Map)['content'],
          '<p><img src="../hostedContents/1/\$value" alt="x.png"></p>');
    });
  });

  group('editing', () {
    ChatMessage mine(String id, {String? replyToId}) => ChatMessage(
          id: id,
          createdAt: DateTime(2026),
          senderName: 'Me',
          senderUserId: 'u-me',
          bodyHtml: 'old',
          editableText: 'old',
          replyToId: replyToId,
        );

    test('a chat message, a post and a reply each go to their own PATCH',
        () async {
      routes['/chats/19:c/messages/m1'] = (o) {
        expect(o.method, 'PATCH');
        expect(o.data, {
          'body': {'contentType': 'text', 'content': 'a < b\nc'},
        });
        return <String, Object?>{};
      };
      routes['/teams/T/channels/19:ch/messages/p1'] = (_) => <String, Object?>{};
      routes['/teams/T/channels/19:ch/messages/p1/replies/r1'] =
          (_) => <String, Object?>{};
      final ds = datasource();
      final edited = await ds.edit(
          const ChatConversation(
              id: '19:c', kind: ChatKind.oneOnOne, title: 'Ann'),
          mine('m1'),
          'a < b\nc');
      expect(edited.bodyHtml, 'a &lt; b<br>c');
      expect(edited.editableText, 'a < b\nc');
      expect(edited.editedAt, isNotNull);

      const channel = ChatConversation(
          id: '19:ch',
          kind: ChatKind.channel,
          title: 'General',
          teamId: 'T');
      await ds.edit(channel, mine('p1'), 'x');
      await ds.edit(channel, mine('r1', replyToId: 'p1'), 'y');
      expect(requests.map((r) => r.uri.path.split('/v1.0').last), [
        '/chats/19:c/messages/m1',
        '/teams/T/channels/19:ch/messages/p1',
        '/teams/T/channels/19:ch/messages/p1/replies/r1',
      ]);
    });

    test('a Microsoft 365 channel cannot be edited without its scope', () {
      const channel = ChatConversation(
          id: '19:ch', kind: ChatKind.channel, title: 'G', teamId: 'T');
      const chat =
          ChatConversation(id: '19:c', kind: ChatKind.oneOnOne, title: 'A');
      expect(datasource(server: false).canEdit(channel), isFalse);
      expect(datasource(server: false).canEdit(chat), isTrue);
      expect(datasource().canEdit(channel), isTrue);
    });

    test('typed text is editable; mentions, attachments and markup are not',
        () {
      String? of(Map<String, dynamic> raw) =>
          GraphChatDatasource.editableTextOf(raw);
      Map<String, dynamic> html(String content) => {
            'body': {'contentType': 'html', 'content': content},
          };
      expect(of({'body': {'contentType': 'text', 'content': 'a < b'}}),
          'a < b');
      expect(of(html('<p>one &amp; two</p>\n<p>three<br>four</p>')),
          'one & two\nthree\nfour');
      expect(
          of(html('<p>hi <emoji id="smile" alt="😄" title="Smile"></emoji> '
              'see <a href="https://x.test/a" rel="noreferrer">'
              'https://x.test/a</a></p>')),
          'hi 😄 see https://x.test/a');
      expect(of(html('<p><a href="https://x.test">the doc</a></p>')), isNull);
      expect(of(html('<p><b>bold</b></p>')), isNull);
      expect(of({...html('<p>hi <at id="0">Ann</at></p>'), 'mentions': [{}]}),
          isNull);
      expect(
          of({
            ...html('<attachment id="1"></attachment><p>re</p>'),
            'attachments': [{}],
          }),
          isNull);
    });
  });

  group('reactions', () {
    ChatMessage anyones(String id, {String? replyToId}) => ChatMessage(
          id: id,
          createdAt: DateTime(2026),
          senderName: 'Ann',
          senderUserId: 'u-ann',
          bodyHtml: 'hi',
          replyToId: replyToId,
        );

    test('setReaction goes to a chat message, a post and a reply, as unicode',
        () async {
      routes['/setReaction'] = (o) {
        expect(o.method, 'POST');
        expect(o.data, {'reactionType': '🎉'});
        return <String, Object?>{};
      };
      final ds = datasource(server: false);
      const chat =
          ChatConversation(id: '19:c', kind: ChatKind.oneOnOne, title: 'Ann');
      const channel = ChatConversation(
          id: '19:ch', kind: ChatKind.channel, title: 'G', teamId: 'T');
      expect(await ds.react(chat, anyones('m1'), '🎉'), isTrue);
      await ds.react(channel, anyones('p1'), '🎉');
      await ds.react(channel, anyones('r1', replyToId: 'p1'), '🎉');
      expect(requests.map((r) => r.uri.path.split('/v1.0').last), [
        '/chats/19:c/messages/m1/setReaction',
        '/teams/T/channels/19:ch/messages/p1/setReaction',
        '/teams/T/channels/19:ch/messages/p1/replies/r1/setReaction',
      ]);
      expect(ds.canReact(channel), isTrue,
          reason: 'ChannelMessage.Send covers a channel reaction');
    });

    test('a reaction keeps who gave it', () async {
      routes['/chats/c/messages'] = (_) => {
            'value': [
              {
                'id': '1',
                'createdDateTime': '2026-11-23T01:00:00Z',
                'body': {'contentType': 'text', 'content': 'hi'},
                'reactions': [
                  {
                    'reactionType': 'like',
                    'user': {
                      'user': {'id': 'u-me'},
                    },
                  },
                  {
                    'reactionType': '👍',
                    'user': {
                      'user': {'id': 'u-ann'},
                    },
                  },
                ],
              },
            ],
          };
      final page = await datasource().messages(
          const ChatConversation(id: 'c', kind: ChatKind.group, title: 'G'));
      expect(page.messages.single.reactions.single,
          const ChatReaction(emoji: '👍', count: 2, userIds: ['u-me', 'u-ann']));
    });

    test('unsetReaction goes where setReaction does', () async {
      routes['/unsetReaction'] = (o) {
        expect(o.method, 'POST');
        expect(o.data, {'reactionType': '🎉'});
        return <String, Object?>{};
      };
      const channel = ChatConversation(
          id: '19:ch', kind: ChatKind.channel, title: 'G', teamId: 'T');
      expect(
          await datasource(server: false)
              .unreact(channel, anyones('r1', replyToId: 'p1'), '🎉'),
          isTrue);
      expect(requests.single.uri.path,
          endsWith('/teams/T/channels/19:ch/messages/p1/replies/r1/unsetReaction'));
    });
  });

  test('a Teams chat has no threads; a channel does', () {
    final ds = datasource(server: false);
    expect(
        ds.canThread(const ChatConversation(
            id: '19:c', kind: ChatKind.group, title: 'G')),
        isFalse);
    expect(
        ds.canThread(const ChatConversation(
            id: '19:ch', kind: ChatKind.channel, title: 'G', teamId: 'T')),
        isTrue);
  });

  group('mentions', () {
    const bob = ChatMember(displayName: 'Bob & Co', userId: 'u-bob');
    const chat = ChatConversation(id: 'c', kind: ChatKind.group, title: 'G');

    test('a tag goes as <at> in an html body, each occurrence its own id',
        () async {
      routes['/chats/c/messages'] = (_) => {
            'id': '9',
            'createdDateTime': '2026-11-23T01:00:00Z',
            'body': {'contentType': 'html', 'content': 'x'},
          };
      await datasource().send(chat, '@Bob & Co <hi>\n@Bob & Co',
          mentions: [bob]);
      final body = requests.single.data as Map;
      expect(body['body'], {
        'contentType': 'html',
        'content': '<p><at id="0">Bob &amp; Co</at> &lt;hi&gt;<br>'
            '<at id="1">Bob &amp; Co</at></p>',
      });
      expect((body['mentions'] as List).map((m) => m['id']), [0, 1]);
      expect((body['mentions'] as List).first, {
        'id': 0,
        'mentionText': 'Bob & Co',
        'mentioned': {
          'user': {
            'id': 'u-bob',
            'displayName': 'Bob & Co',
            'userIdentityType': 'aadUser',
          },
        },
      });
    });

    test('a pick no longer in the text sends plain text, as before',
        () async {
      routes['/chats/c/messages'] = (_) => {
            'id': '9',
            'createdDateTime': '2026-11-23T01:00:00Z',
            'body': {'contentType': 'text', 'content': 'hi Bob'},
          };
      await datasource().send(chat, 'hi Bob', mentions: [bob]);
      expect(requests.single.data,
          {'body': {'contentType': 'text', 'content': 'hi Bob'}});
    });

    test('a chat lists its members; a Microsoft 365 channel asks nothing',
        () async {
      routes['/chats/c/members'] = (_) => {
            'value': [
              {'displayName': 'Bob', 'userId': 'u-bob', 'email': 'Bob@X.com'},
              {'displayName': 'Guest', 'userId': null},
            ],
          };
      final members = await datasource().mentionable(chat);
      expect(members, [
        const ChatMember(displayName: 'Bob', userId: 'u-bob', email: 'bob@x.com'),
      ]);
      requests.clear();
      const channel = ChatConversation(
          id: 'ch', kind: ChatKind.channel, title: 'G', teamId: 't');
      expect(await datasource(server: false).mentionable(channel), isEmpty);
      expect(requests, isEmpty);
      // A NightMail Server lists a channel's members.
      routes['/teams/t/channels/ch/members'] = (_) => {
            'value': [
              {'displayName': 'Bob', 'userId': 'u-bob'},
            ],
          };
      expect((await datasource().mentionable(channel)).single.userId, 'u-bob');
    });
  });

  group('calls', () {
    const chat = ChatConversation(
      id: '19:g',
      kind: ChatKind.group,
      title: 'Group',
      members: [
        ChatMember(
            displayName: 'Outside Olly', userId: 'ext-1', email: 'olly@other.example'),
      ],
    );

    test('Microsoft 365: a Teams call link to the UPN, video on request',
        () async {
      routes['/users/u-1'] = (o) {
        expect(o.uri.queryParameters[r'$select'], 'userPrincipalName,mail');
        return {
          'userPrincipalName': 'Ann.Lee_contoso.com#EXT#@Tenant.onmicrosoft.com',
          'mail': 'ann@contoso.com',
        };
      };
      final ds = datasource(server: false);
      const ann = ChatMember(displayName: 'Ann', userId: 'u-1');

      expect(ds.calling, ChatCalling.voiceAndVideo);
      final voice = await ds.callLink(chat, ann, video: false);
      expect(voice,
          'https://teams.microsoft.com/l/call/0/0?users=ann.lee_contoso.com%23ext%23@tenant.onmicrosoft.com');
      final video = await ds.callLink(chat, ann, video: true);
      expect(video, endsWith('@tenant.onmicrosoft.com&withVideo=true'));
      // The address is asked once; the call link itself posts nothing.
      expect(requests.where((r) => r.path.contains('/users/')), hasLength(1));
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
    });

    test('Microsoft 365: someone outside the directory by the address the '
        'conversation lists', () async {
      routes['/users/ext-1'] = (_) => 404;
      final link = await datasource(server: false).callLink(
          chat, const ChatMember(displayName: 'Olly', userId: 'ext-1'),
          video: false);
      expect(link,
          'https://teams.microsoft.com/l/call/0/0?users=olly@other.example');
    });

    test('NightMail Server: Talk rings them and the join link comes back, '
        'never a Teams link', () async {
      Map<String, dynamic>? body;
      routes['/communications/calls'] = (o) {
        body = o.data as Map<String, dynamic>;
        return {
          'id': 'sealed',
          '@nightware.joinWebUrl': 'https://talk.example.com/call/abcd1234',
        };
      };
      final link = await datasource().callLink(
          chat, const ChatMember(displayName: 'Ann', userId: 'kc-ann'),
          video: true);
      expect(link, 'https://talk.example.com/call/abcd1234');
      expect(body, {
        'targets': [
          {
            'identity': {
              'user': {'id': 'kc-ann'},
            },
          },
        ],
        'requestedModalities': ['audio', 'video'],
      });
      expect(requests.single.method, 'POST');
    });

    test('NightMail Server: calls switched off read as such', () async {
      routes['/communications/calls'] = (_) => 501;
      await expectLater(
        datasource().callLink(
            chat, const ChatMember(displayName: 'Ann', userId: 'kc-ann'),
            video: false),
        throwsA(isA<ServerException>().having((e) => e.message, 'message',
            'Calls are not turned on for this NightMail Server.')),
      );
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
