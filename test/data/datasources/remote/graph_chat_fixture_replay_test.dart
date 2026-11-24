import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/graph_chat_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';

/// Nightware's conformance fixtures for chats and channels (copied from
/// `nightware/tests/Nightware.Conformance.Tests/Fixtures`), replayed through
/// the datasource's parser. Nightware built them from Microsoft's reference
/// pages, so they stand for both providers' answers — real response shapes
/// rather than the hand-written ones in graph_chat_datasource_test.dart.
/// Refresh the copies when nightware changes a chat fixture.
void main() {
  Map<String, dynamic> fixture(String name) => jsonDecode(
          File('test/fixtures/nightware_chat/$name.json').readAsStringSync())
      as Map<String, dynamic>;

  /// Answers each request with the fixture whose recorded path ends the
  /// request's path. The account's root is not the fixtures' host, so their
  /// `@odata.nextLink`s are (rightly) not followed.
  GraphChatDatasource replaying(List<String> names) {
    final byPath = {
      for (final n in names)
        (fixture(n)['request']['path'] as String).replaceFirst('/v1.0', ''): n,
    };
    final dio = Dio(BaseOptions(baseUrl: 'https://mail.example.org/v1.0'))
      ..httpClientAdapter = _StubAdapter((o) async {
        final path = o.uri.path.replaceFirst('/v1.0', '');
        final name = byPath[path];
        if (name == null) {
          return ResponseBody.fromString('{}', 404, headers: _json);
        }
        final response = fixture(name)['response'] as Map<String, dynamic>;
        return ResponseBody.fromString(
            jsonEncode(response['body']), response['status'] as int,
            headers: _json);
      });
    return GraphChatDatasource(
      dio: dio,
      ownAddresses: {'alice@example.com'},
      isNightmailServer: true,
    );
  }

  test('chats.list', () async {
    final chats = await replaying(['chats.list']).listChats();
    expect(chats.map((c) => c.id), ['5opkrcg6', 'nge9dkks']);
    expect(chats.first.kind, ChatKind.group);
    expect(chats.first.title, 'Project review');
    expect(chats.last.kind, ChatKind.oneOnOne);
    expect(chats.first.lastActivity, isNotNull);
  });

  test('chats.messages.list: file references and edits', () async {
    final page = await replaying(['chats.messages.list']).messages(
        const ChatConversation(
            id: '5opkrcg6', kind: ChatKind.group, title: 'Project review'));
    expect(page.messages, isNotEmpty);
    final withFile = page.messages.firstWhere((m) => m.id == '76');
    expect(withFile.senderName, 'Alice Anderson');
    expect(withFile.attachmentNames, ['notes.txt']);
    expect(page.messages.firstWhere((m) => m.id == '59').editedAt, isNotNull);
    // Newest first, whatever order the page came in.
    for (var i = 1; i < page.messages.length; i++) {
      expect(
          page.messages[i - 1].createdAt
              .isBefore(page.messages[i].createdAt),
          isFalse);
    }
  });

  test('chats.messages.send answer parses as the sent message', () async {
    final sent = await replaying(['chats.messages.send']).send(
        const ChatConversation(
            id: '5opkrcg6', kind: ChatKind.group, title: 'Project review'),
        'hello');
    expect(sent.id, isNotEmpty);
    expect(sent.bodyHtml, contains('Bob Brown'));
  });

  test('chats.create answer parses as the new chat', () async {
    final chat = await replaying(['chats.create']).createOneOnOne(
      ownEmail: 'alice@example.com',
      email: 'bob@example.com',
      displayName: 'Bob Brown',
    );
    expect(chat.id, isNotEmpty);
    expect(chat.title, 'Bob Brown');
  });

  test('teams.joined and channels.list', () async {
    final channels =
        await replaying(['teams.joined', 'channels.list']).listChannels();
    expect(channels, isNotEmpty);
    expect(channels.every((c) => c.isChannel && c.teamId != null), isTrue);
    expect(channels.first.teamName, isNotEmpty);
  });

  test('channels.messages.list and channels.replies.list', () async {
    const channel = ChatConversation(
      id: 'hktd6xvp',
      kind: ChatKind.channel,
      title: 'General',
      teamId: 'Pq7Xk2LmN9vRt4WzYc8BdHf3JsQa6Ue',
    );
    final ds = replaying(['channels.messages.list', 'channels.replies.list']);
    final page = await ds.messages(channel);
    final kickOff = page.messages.firstWhere((m) => m.id == '100');
    expect(kickOff.subject, 'Kick-off');
    expect(page.messages.firstWhere((m) => m.id == '106').subject, isNull);

    final replies = await ds.replies(channel, kickOff);
    expect(replies, isNotEmpty);
    for (var i = 1; i < replies.length; i++) {
      expect(replies[i].createdAt.isBefore(replies[i - 1].createdAt), isFalse);
    }
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
