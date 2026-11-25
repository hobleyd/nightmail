import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/google_chat_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';

/// Google Chat as the signed-in Workspace user: spaces as conversations,
/// direct messages found and started by address, threaded spaces as posts
/// with replies.
void main() {
  late List<RequestOptions> requests;
  late Map<String, Object? Function(RequestOptions)> routes;

  GoogleChatDatasource datasource({String own = 'me@example.com'}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://chat.googleapis.com/v1'))
      ..httpClientAdapter = _StubAdapter((o) async {
        requests.add(o);
        final path = Uri.decodeComponent(o.uri.path);
        final handler = routes.entries
            .where((e) => path.endsWith(e.key))
            .firstOrNull
            ?.value;
        final body = handler == null ? 404 : handler(o);
        if (body is int) {
          return ResponseBody.fromString(
              jsonEncode({
                'error': {'message': 'status $body'}
              }),
              body,
              headers: _json);
        }
        if (body is String) {
          return ResponseBody.fromString(
              jsonEncode({
                'error': {'message': body}
              }),
              403,
              headers: _json);
        }
        return ResponseBody.fromString(jsonEncode(body), 200, headers: _json);
      });
    return GoogleChatDatasource(dio: dio, ownEmail: own);
  }

  setUp(() {
    requests = [];
    routes = {};
    GoogleChatDatasource.forgetIdentities();
  });

  group('changes since', () {
    test('a DM asks for what was created after the watermark', () async {
      routes['spaces/D/messages'] = (o) {
        expect(o.queryParameters['filter'],
            'createTime > "2026-11-25T09:00:00.000Z"');
        return {
          'messages': [
            {
              'name': 'spaces/D/messages/m2',
              'createTime': '2026-11-25T09:02:00Z',
              'sender': {'name': 'users/1', 'displayName': 'Ann'},
              'text': 'hi',
            },
          ],
        };
      };
      final d = await datasource().messagesSince(
          const ChatConversation(
              id: 'spaces/D', kind: ChatKind.oneOnOne, title: 'Ann'),
          DateTime.utc(2026, 11, 25, 9));
      expect(d!.messages.single.id, 'spaces/D/messages/m2');
      expect(d.watermark!.isAtSameMomentAs(DateTime.utc(2026, 11, 25, 9, 2)),
          isTrue);
    });

    test('a threaded space reads full pages', () async {
      expect(
          await datasource().messagesSince(
              const ChatConversation(
                  id: 'spaces/S',
                  kind: ChatKind.space,
                  title: 'S',
                  threaded: true),
              DateTime.utc(2026)),
          isNull);
      expect(requests, isEmpty);
    });
  });

  group('unread', () {
    Map<String, dynamic> space(String id, String active) => {
          'name': 'spaces/$id',
          'spaceType': 'SPACE',
          'displayName': id,
          'lastActiveTime': active,
        };

    void serve({required String newestSender}) {
      routes['/spaces'] = (_) => {
            'spaces': [
              space('read', '2026-11-25T09:00:00Z'),
              space('fresh', '2026-11-25T10:00:00Z'),
            ],
          };
      routes['/members/me@example.com'] = (_) => {
            'member': {'name': 'users/me'},
          };
      routes['/spaces/read/spaceReadState'] =
          (_) => {'lastReadTime': '2026-11-25T09:00:00Z'};
      routes['/spaces/fresh/spaceReadState'] =
          (_) => {'lastReadTime': '2026-11-25T08:00:00Z'};
      routes['/spaces/fresh/messages'] = (_) => {
            'messages': [
              {
                'name': 'spaces/fresh/messages/m',
                'sender': {'name': newestSender},
              },
            ],
          };
    }

    test('a space someone wrote in after the read time is unread', () async {
      serve(newestSender: 'users/ann');
      final chats = await datasource().listRecentChats();
      expect(chats.where((c) => c.unread).map((c) => c.id), ['spaces/fresh']);
      expect(
          requests.where((r) => r.uri.path.endsWith('/spaces/read/messages')),
          isEmpty,
          reason: 'read up to its last activity: no message lookup');
    });

    test('an unread direct message is named by who wrote it', () async {
      serve(newestSender: 'users/ann');
      routes['/spaces'] = (_) => {
            'spaces': [
              {
                'name': 'spaces/fresh',
                'spaceType': 'DIRECT_MESSAGE',
                'lastActiveTime': '2026-11-25T10:00:00Z',
              },
            ],
          };
      routes['/spaces/fresh/messages'] = (_) => {
            'messages': [
              {
                'name': 'spaces/fresh/messages/m',
                'sender': {'name': 'users/ann', 'displayName': 'Ann Lee'},
              },
            ],
          };
      final chats = await datasource().listRecentChats();
      expect(chats.single.title, 'Ann Lee');
    });

    test('the user\'s own last message is not unread', () async {
      serve(newestSender: 'users/me');
      final chats = await datasource().listRecentChats();
      expect(chats.where((c) => c.unread), isEmpty);
    });

    test('a quiet poll is the one listing', () async {
      serve(newestSender: 'users/ann');
      final ds = datasource();
      await ds.listRecentChats();
      requests.clear();
      final again = await ds.listRecentChats();
      expect(requests.map((r) => r.uri.path), [endsWith('/spaces')]);
      expect(again.where((c) => c.unread).map((c) => c.id), ['spaces/fresh']);
    });

    test('mark read sets the read time to now, and the cache follows',
        () async {
      serve(newestSender: 'users/ann');
      final ds = datasource();
      await ds.listRecentChats();
      routes['/spaces/fresh/spaceReadState'] = (_) => <String, dynamic>{};
      await ds.markRead(const ChatConversation(
          id: 'spaces/fresh', kind: ChatKind.space, title: 'fresh'));
      final patch = requests.last;
      expect(patch.method, 'PATCH');
      expect(patch.uri.path, endsWith('/users/me/spaces/fresh/spaceReadState'));
      expect(patch.uri.queryParameters['updateMask'], 'lastReadTime');
      expect((patch.data as Map)['lastReadTime'], isA<String>());

      final after = await ds.listRecentChats();
      expect(after.where((c) => c.unread), isEmpty);
    });
  });

  test('spaces become chats, newest first; DMs are titled by the other person',
      () async {
    routes['/spaces'] = (_) => {
          'spaces': [
            {
              'name': 'spaces/old',
              'spaceType': 'SPACE',
              'displayName': 'Launch',
              'spaceThreadingState': 'THREADED_MESSAGES',
              'lastActiveTime': '2026-11-20T00:00:00Z',
            },
            {
              'name': 'spaces/dm1',
              'spaceType': 'DIRECT_MESSAGE',
              'lastActiveTime': '2026-11-23T00:00:00Z',
            },
          ],
        };
    routes['/spaces/dm1/members/me@example.com'] = (_) => {
          'member': {'name': 'users/111', 'type': 'HUMAN'},
        };
    routes['/spaces/dm1/members'] = (_) => {
          'memberships': [
            {
              'member': {
                'name': 'users/111',
                'displayName': 'Me',
                'type': 'HUMAN'
              }
            },
            {
              'member': {
                'name': 'users/222',
                'displayName': 'Bob Brown',
                'type': 'HUMAN'
              }
            },
          ],
        };
    final chats = await datasource().listChats();
    expect(chats.map((c) => c.id), ['spaces/dm1', 'spaces/old']);
    expect(chats.first.kind, ChatKind.oneOnOne);
    expect(chats.first.title, 'Bob Brown');
    expect(chats.last.kind, ChatKind.space);
    expect(chats.last.threaded, isTrue);
    expect(chats.last.hasThreads, isTrue);
    expect(chats.map((c) => c.noMessages), everyElement(isFalse));
  });

  test('a space without a last active time has never had a message',
      () async {
    routes['/spaces'] = (_) => {
          'spaces': [
            {
              'name': 'spaces/new',
              'spaceType': 'SPACE',
              'displayName': 'Made, never used',
              'createTime': '2026-11-24T00:00:00Z',
            },
          ],
        };
    final chats = await datasource().listChats();
    expect(chats.single.noMessages, isTrue);
  });

  test('a DM is found by address; none is a null, not an error', () async {
    routes['/spaces:findDirectMessage'] = (o) {
      expect(o.uri.queryParameters['name'], 'users/bob@example.com');
      return 404;
    };
    expect(await datasource().findOneOnOne('bob@example.com'), isNull);

    routes['/spaces:findDirectMessage'] = (_) => {
          'name': 'spaces/dm9',
          'spaceType': 'DIRECT_MESSAGE',
        };
    final found = await datasource().findOneOnOne('bob@example.com');
    expect(found?.id, 'spaces/dm9');
    expect(found?.kind, ChatKind.oneOnOne);
  });

  test('a DM is started with spaces.setup naming the other person', () async {
    Map<String, dynamic>? sent;
    routes['/spaces:setup'] = (o) {
      sent = o.data as Map<String, dynamic>;
      return {'name': 'spaces/new', 'spaceType': 'DIRECT_MESSAGE'};
    };
    final chat = await datasource().createOneOnOne(
        ownEmail: 'me@example.com', email: 'bob@example.com', displayName: 'Bob');
    expect(sent!['space'], {'spaceType': 'DIRECT_MESSAGE', 'singleUserBotDm': false});
    expect(sent!['memberships'], [
      {
        'member': {'name': 'users/bob@example.com', 'type': 'HUMAN'}
      }
    ]);
    expect(chat.id, 'spaces/new');
    expect(chat.title, 'Bob');
  });

  test('a threaded space lists posts with the replies on the page', () async {
    routes['/spaces/s/messages'] = (o) {
      expect(o.uri.queryParameters['orderBy'], 'createTime DESC');
      return {
        'messages': [
          {
            'name': 'spaces/s/messages/r1',
            'createTime': '2026-11-23T02:00:00Z',
            'text': 'reply',
            'thread': {'name': 'spaces/s/threads/t1'},
            'threadReply': true,
            'sender': {'name': 'users/2', 'displayName': 'Bob'},
          },
          {
            'name': 'spaces/s/messages/p1',
            'createTime': '2026-11-23T01:00:00Z',
            'text': '*plan* for _today_',
            'thread': {'name': 'spaces/s/threads/t1'},
            'sender': {'name': 'users/1', 'displayName': 'Ann'},
            'emojiReactionSummaries': [
              {
                'emoji': {'unicode': '🎉'},
                'reactionCount': 3
              }
            ],
          },
        ],
      };
    };
    const space = ChatConversation(
        id: 'spaces/s', kind: ChatKind.space, title: 'S', threaded: true);
    final page = await datasource().messages(space);
    final post = page.messages.single;
    expect(post.id, 'spaces/s/messages/p1');
    expect(post.senderName, 'Ann');
    expect(post.bodyHtml, '<b>plan</b> for <i>today</i>');
    expect(post.threadId, 'spaces/s/threads/t1');
    expect(post.replies.single.bodyHtml, 'reply');
    expect(post.reactions.single, const ChatReaction(emoji: '🎉', count: 3));
    expect(page.nextLink, isNull);
  });

  test('a page of nothing but replies reads on until there are posts',
      () async {
    var calls = 0;
    routes['/spaces/s/messages'] = (o) {
      calls++;
      if (o.uri.queryParameters['pageToken'] == null) {
        return {
          'messages': [
            for (var i = 0; i < 3; i++)
              {
                'name': 'spaces/s/messages/r$i',
                'createTime': '2026-11-23T0$i:30:00Z',
                'thread': {'name': 'spaces/s/threads/t1'},
                'threadReply': true,
              },
          ],
          'nextPageToken': 'older',
        };
      }
      return {
        'messages': [
          {
            'name': 'spaces/s/messages/p1',
            'createTime': '2026-11-22T00:00:00Z',
            'thread': {'name': 'spaces/s/threads/t1'},
          },
        ],
      };
    };
    final page = await datasource().messages(const ChatConversation(
        id: 'spaces/s', kind: ChatKind.space, title: 'S', threaded: true));
    expect(calls, 2);
    expect(page.messages.single.id, 'spaces/s/messages/p1');
    expect(page.messages.single.replies, hasLength(3));
  });

  test('an unthreaded chat reads one page', () async {
    var calls = 0;
    routes['/spaces/g/messages'] = (_) {
      calls++;
      return {
        'messages': <Object>[],
        'nextPageToken': 'older',
      };
    };
    final page = await datasource().messages(const ChatConversation(
        id: 'spaces/g', kind: ChatKind.group, title: 'G'));
    expect(calls, 1);
    expect(page.nextLink, 'older');
  });

  test('a reply goes to the post\'s thread', () async {
    routes['/spaces/s/messages'] = (o) {
      return {
        'name': 'spaces/s/messages/r2',
        'createTime': '2026-11-23T03:00:00Z',
        'text': (o.data as Map)['text'],
      };
    };
    final post = ChatMessage(
      id: 'spaces/s/messages/p1',
      createdAt: DateTime(2026),
      senderName: 'Ann',
      bodyHtml: '',
      threadId: 'spaces/s/threads/t1',
    );
    await datasource().send(
        const ChatConversation(
            id: 'spaces/s', kind: ChatKind.space, title: 'S', threaded: true),
        'ok',
        replyTo: post);
    final r = requests.single;
    expect((r.data as Map)['thread'], {'name': 'spaces/s/threads/t1'});
    expect(r.uri.queryParameters['messageReplyOption'],
        'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD');
  });

  test('a thread\'s replies are read by thread name, without the post',
      () async {
    routes['/spaces/s/messages'] = (o) {
      expect(o.uri.queryParameters['filter'],
          'thread.name = spaces/s/threads/t1');
      return {
        'messages': [
          {'name': 'spaces/s/messages/p1', 'createTime': '2026-11-23T01:00:00Z'},
          {'name': 'spaces/s/messages/r1', 'createTime': '2026-11-23T02:00:00Z'},
        ],
      };
    };
    final replies = await datasource().replies(
      const ChatConversation(
          id: 'spaces/s', kind: ChatKind.space, title: 'S', threaded: true),
      ChatMessage(
        id: 'spaces/s/messages/p1',
        createdAt: DateTime(2026),
        senderName: '',
        bodyHtml: '',
        threadId: 'spaces/s/threads/t1',
      ),
    );
    expect(replies.map((m) => m.id), ['spaces/s/messages/r1']);
  });

  test('a project without a Chat app says so in words', () async {
    routes['/spaces'] = (_) => 'Google Chat app not found. To create a Chat app, '
        'you must turn on the Chat API and configure the app.';
    await expectLater(
      datasource().listChats(),
      throwsA(isA<ServerException>().having(
          (e) => e.message, 'message', contains('not set up for NightMail'))),
    );
  });

  test('text is escaped before Chat markup is styled', () {
    expect(GoogleChatDatasource.chatTextToHtml('a <b> & *c*\nd'),
        'a &lt;b&gt; &amp; <b>c</b><br>d');
    expect(GoogleChatDatasource.chatTextToHtml('see https://x.example/a'),
        'see <a href="https://x.example/a">https://x.example/a</a>');
    expect(GoogleChatDatasource.chatTextToHtml('snake_case_name'),
        'snake_case_name');
  });

  group('editing', () {
    test('patches the text alone and takes the server\'s rendering', () async {
      routes['spaces/D/messages/M1'] = (o) {
        expect(o.method, 'PATCH');
        expect(o.queryParameters['updateMask'], 'text');
        expect(o.data, {'text': 'new *one*'});
        return {
          'name': 'spaces/D/messages/M1',
          'text': 'new *one*',
          'lastUpdateTime': '2026-11-25T10:00:00Z',
          'sender': {'name': 'users/me'},
        };
      };
      final edited = await datasource().edit(
        const ChatConversation(
            id: 'spaces/D', kind: ChatKind.oneOnOne, title: 'Ann'),
        ChatMessage(
          id: 'spaces/D/messages/M1',
          createdAt: DateTime(2026),
          senderName: 'Me',
          senderUserId: 'users/me',
          bodyHtml: 'old',
          editableText: 'old',
          threadId: 'spaces/D/threads/T',
        ),
        'new *one*',
      );
      expect(edited.bodyHtml, 'new <b>one</b>');
      expect(edited.editableText, 'new *one*');
      expect(edited.editedAt, DateTime.utc(2026, 11, 25, 10).toLocal());
      expect(edited.threadId, 'spaces/D/threads/T');
    });

    test('a mention or labelled link is not offered for editing', () {
      expect(GoogleChatDatasource.editableTextOf({'text': 'a < b'}), 'a < b');
      expect(
          GoogleChatDatasource.editableTextOf({'text': 'hi <users/123>'}),
          isNull);
      expect(
          GoogleChatDatasource.editableTextOf(
              {'text': '<https://x.test|doc>'}),
          isNull);
      expect(GoogleChatDatasource.editableTextOf({'text': ''}), isNull);
      expect(
          GoogleChatDatasource.editableTextOf({
            'text': 'thanks @Ann Lee',
            'annotations': [
              {'type': 'USER_MENTION', 'startIndex': 7, 'length': 8},
            ],
          }),
          isNull,
          reason: 'a read mention is plain text with an annotation over it');
    });
  });

  group('reactions', () {
    const chat =
        ChatConversation(id: 'spaces/D', kind: ChatKind.oneOnOne, title: 'A');
    final message = ChatMessage(
      id: 'spaces/D/messages/M1',
      createdAt: DateTime(2026),
      senderName: 'Ann',
      bodyHtml: 'hi',
    );

    test('reactions.create with the emoji\'s unicode', () async {
      routes['spaces/D/messages/M1/reactions'] = (o) {
        expect(o.method, 'POST');
        expect(o.data, {
          'emoji': {'unicode': '👍'},
        });
        return {'name': 'spaces/D/messages/M1/reactions/R1'};
      };
      expect(await datasource().react(chat, message, '👍'), isTrue);
    });

    test('a repeat (409) is the user\'s reaction already there', () async {
      routes['spaces/D/messages/M1/reactions'] = (_) => 409;
      expect(await datasource().react(chat, message, '👍'), isFalse);
    });

    test('any other refusal fails', () async {
      routes['spaces/D/messages/M1/reactions'] = (_) => 400;
      await expectLater(datasource().react(chat, message, '👍'),
          throwsA(isA<ServerException>()));
    });

    test('the user\'s own is found by emoji and user, then deleted', () async {
      routes['/spaces/D/members/un@example.com'] = (_) => {
            'member': {'name': 'users/42'},
          };
      routes['spaces/D/messages/M1/reactions'] = (o) {
        expect(o.method, 'GET');
        expect(o.queryParameters['filter'],
            'emoji.unicode = "👍" AND user.name = "users/42"');
        return {
          'reactions': [
            {'name': 'spaces/D/messages/M1/reactions/R1'},
          ],
        };
      };
      routes['spaces/D/messages/M1/reactions/R1'] = (o) {
        expect(o.method, 'DELETE');
        return <String, Object?>{};
      };
      final ds = datasource(own: 'un@example.com');
      expect(await ds.unreact(chat, message, '👍'), isTrue);
      expect(requests.last.method, 'DELETE');
    });

    test('none of the user\'s to delete says so', () async {
      routes['/spaces/D/members/un2@example.com'] = (_) => {
            'member': {'name': 'users/43'},
          };
      routes['spaces/D/messages/M1/reactions'] = (_) => <String, Object?>{};
      expect(
          await datasource(own: 'un2@example.com').unreact(chat, message, '👍'),
          isFalse);
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });
  });

  test('only a threaded space threads; a DM does not', () {
    final ds = datasource();
    expect(
        ds.canThread(const ChatConversation(
            id: 'spaces/D', kind: ChatKind.oneOnOne, title: 'A')),
        isFalse);
    expect(
        ds.canThread(const ChatConversation(
            id: 'spaces/S',
            kind: ChatKind.space,
            title: 'S',
            threaded: true)),
        isTrue);
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
