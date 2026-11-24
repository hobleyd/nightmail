import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/google_chat_datasource.dart';
import 'package:nightmail/data/datasources/remote/graph_chat_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';

/// Chat images and photos: a picture on the account's own server goes with
/// its token, anything else only over https and never with it; a missing
/// photo is a null, not an error.
void main() {
  late List<RequestOptions> requests;
  late Map<String, (int, String, List<int>)> routes;

  Dio stub(String base) => Dio(BaseOptions(baseUrl: base))
    ..httpClientAdapter = _StubAdapter((o) async {
      requests.add(o);
      final hit = routes.entries
          .where((e) => Uri.decodeComponent(o.uri.path).endsWith(e.key))
          .firstOrNull
          ?.value;
      if (hit == null) {
        return ResponseBody.fromString('{"error":{}}', 404, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
      }
      return ResponseBody.fromBytes(hit.$3, hit.$1, headers: {
        Headers.contentTypeHeader: [hit.$2],
      });
    });

  setUp(() {
    requests = [];
    routes = {};
  });

  group('Graph', () {
    const root = 'https://graph.microsoft.com/v1.0';
    GraphChatDatasource ds({bool server = false}) => GraphChatDatasource(
          dio: stub(root),
          ownAddresses: const {'me@example.com'},
          isNightmailServer: server,
        );

    test('hosted content on the account\'s own root is fetched with it',
        () async {
      routes['/hostedContents/h1/\$value'] = (200, 'image/png', [1, 2, 3]);
      final bytes = await ds().image(
          '$root/chats/c/messages/m/hostedContents/h1/\$value');
      expect(bytes, [1, 2, 3]);
      expect(requests.single.uri.host, 'graph.microsoft.com');
    });

    test('plain http elsewhere is never fetched', () async {
      expect(await ds().image('http://tracker.example/p.gif'), isNull);
      expect(requests, isEmpty);
    });

    test('an answer that is not an image is no image', () async {
      routes['/hostedContents/h2/\$value'] = (200, 'text/html', utf8.encode('<html>'));
      expect(
          await ds().image('$root/chats/c/messages/m/hostedContents/h2/\$value'),
          isNull);
    });

    test('Microsoft photos are the 64-pixel rendition; a 404 is null',
        () async {
      routes['/users/u1/photos/64x64/\$value'] = (200, 'image/jpeg', [9]);
      expect(await ds().photo('u1'), [9]);
      expect(await ds().photo('nobody'), isNull);
    });

    test('a NightMail Server serves the photo itself', () async {
      routes['/users/u1/photo/\$value'] = (200, 'image/jpeg', [7]);
      expect(await ds(server: true).photo('u1'), [7]);
    });
  });

  group('Google', () {
    GoogleChatDatasource ds() => GoogleChatDatasource(
        dio: stub('https://chat.googleapis.com/v1'), ownEmail: 'me@example.com');

    test('an uploaded picture becomes an image in the body, fetched as media',
        () async {
      routes['/spaces/s/messages'] = (
        200,
        Headers.jsonContentType,
        utf8.encode(jsonEncode({
          'messages': [
            {
              'name': 'spaces/s/messages/1',
              'createTime': '2026-11-20T10:00:00Z',
              'text': 'see',
              'attachment': [
                {
                  'contentName': 'shot.png',
                  'contentType': 'image/png',
                  'attachmentDataRef': {'resourceName': 'R1=='},
                },
                {
                  'contentName': 'plan.docx',
                  'contentType': 'application/vnd.openxmlformats',
                  'driveDataRef': {'driveFileId': 'd'},
                },
              ],
            },
          ],
        })),
      );
      final page = await ds().messages(const ChatConversation(
          id: 'spaces/s', kind: ChatKind.group, title: 'S'));
      final m = page.messages.single;
      expect(m.attachmentNames, ['plan.docx']);
      final src = RegExp(r'src="([^"]+)"').firstMatch(m.bodyHtml)!.group(1)!;
      expect(src, startsWith('${GoogleChatDatasource.mediaScheme}:'));

      routes['/media/R1=='] = (200, 'image/png', [5, 6]);
      expect(await ds().image(src), [5, 6]);
      expect(requests.last.uri.queryParameters['alt'], 'media');
    });

    test('a person without a photo of their own has none', () async {
      routes['/people/123'] = (
        200,
        Headers.jsonContentType,
        utf8.encode(jsonEncode({
          'photos': [
            {'url': 'https://lh3.googleusercontent.com/a=s100', 'default': true},
          ],
        })),
      );
      expect(await ds().photo('users/123'), isNull);
    });
  });
}

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
