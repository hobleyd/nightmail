import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/domain/entities/email.dart';

import 'graph_api_get_emails_test.mocks.dart';

Map<String, dynamic> _messageJson(
  String id,
  String convId, {
  String parentFolderId = 'inbox',
}) =>
    {
      'id': id,
      'subject': 'Test',
      'from': {
        'emailAddress': {'address': 'a@b.com', 'name': 'A'}
      },
      'toRecipients': <dynamic>[],
      'ccRecipients': <dynamic>[],
      'bodyPreview': '',
      'isRead': true,
      'receivedDateTime': '2026-01-01T00:00:00Z',
      'importance': 'normal',
      'conversationId': convId,
      'hasAttachments': false,
      'parentFolderId': parentFolderId,
    };

Response<String> _resp(
  Map<String, dynamic> data, {
  String path = '',
}) =>
    Response(
      data: jsonEncode(data),
      statusCode: 200,
      requestOptions: RequestOptions(path: path),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  // Regression: _fetchConversationMessages previously used $top: 50, which
  // silently truncated threads with more than 50 messages.  Those unloaded
  // messages were never moved when the user dragged the thread, leaving them
  // in the source folder so the thread reappeared after a refresh.
  group('getEmails — _fetchConversationMessages uses \$top: 200', () {
    test('passes \$top: 200 when fetching cross-folder conversation messages',
        () async {
      // First call: folder messages (contains one email with a conversationId).
      when(mockDio.get<String>(
        '/me/mailFolders/inbox/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_messageJson('msg1', 'conv-1')],
          }));

      // Second call: _fetchConversationMessages for conv-1.
      // Capture the queryParameters so we can assert on $top.
      Map<String, dynamic>? capturedParams;
      when(mockDio.get<String>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>?;
        return _resp({'value': <dynamic>[]});
      });

      await datasource.getEmails(folderId: 'inbox', top: 1);

      expect(capturedParams, isNotNull,
          reason: '_fetchConversationMessages was not called');
      expect(capturedParams!['\$top'], equals(200),
          reason:
              '\$top should be 200 so large threads are fully fetched before a drag-move');
    });

    test('conversation fetch uses \$filter with the correct conversationId',
        () async {
      when(mockDio.get<String>(
        '/me/mailFolders/inbox/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_messageJson('msg1', 'my-conv-id')],
          }));

      Map<String, dynamic>? capturedParams;
      when(mockDio.get<String>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        capturedParams = invocation.namedArguments[#queryParameters]
            as Map<String, dynamic>?;
        return _resp({'value': <dynamic>[]});
      });

      await datasource.getEmails(folderId: 'inbox', top: 1);

      expect(capturedParams!['\$filter'],
          equals("conversationId eq 'my-conv-id'"));
    });
  });

  // Regression: deleting one message of a thread whose other messages are still
  // in the folder put it straight back on screen at every refresh. deleteEmail
  // *moves* the message to Deleted Items, where it keeps its conversationId — so
  // the mailbox-wide conversation fetch handed the deleted copy back — and the
  // move changes its id, so the outbox's pending-op/tombstone reconciliation
  // (keyed on the id that was deleted) could not recognise it either.
  group('getEmails — cross-folder expansion excludes Deleted Items and Junk',
      () {
    const deletedItemsId = 'AQMk-deleted-items';
    const junkId = 'AQMk-junk-email';

    /// Stubs the folder page for [listedFolderId] plus the mailbox-wide
    /// conversation fetch that follows it, and the two well-known folder lookups
    /// the exclusion needs.
    void stubMailbox({
      required String listedFolderId,
      required List<Map<String, dynamic>> folderPage,
      required List<Map<String, dynamic>> conversation,
    }) {
      when(mockDio.get<String>(
        '/me/mailFolders/$listedFolderId/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({'value': folderPage}));

      when(mockDio.get<String>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({'value': conversation}));

      for (final entry in const {
        'deleteditems': deletedItemsId,
        'junkemail': junkId,
      }.entries) {
        when(mockDio.get<Map<String, dynamic>>(
          '/me/mailFolders/${entry.key}',
          queryParameters: anyNamed('queryParameters'),
          options: anyNamed('options'),
        )).thenAnswer((_) async => Response(
              data: {'id': entry.value},
              statusCode: 200,
              requestOptions: RequestOptions(path: '/me/mailFolders'),
            ));
      }
    }

    test('drops the Deleted Items copy of a thread still in the Inbox',
        () async {
      stubMailbox(
        listedFolderId: 'inbox',
        folderPage: [_messageJson('invitation', 'conv-1')],
        conversation: [
          _messageJson('invitation', 'conv-1'),
          // The cancellation the user removed from the calendar: Graph moved it
          // to Deleted Items and gave it a new id.
          _messageJson('cancellation-moved', 'conv-1',
              parentFolderId: deletedItemsId),
        ],
      );

      final emails = await datasource.getEmails(folderId: 'inbox');

      expect(emails.map((e) => e.id), ['invitation']);
    });

    test('drops the Junk Email copy too', () async {
      stubMailbox(
        listedFolderId: 'inbox',
        folderPage: [_messageJson('msg1', 'conv-1')],
        conversation: [
          _messageJson('msg1', 'conv-1'),
          _messageJson('junked', 'conv-1', parentFolderId: junkId),
        ],
      );

      final emails = await datasource.getEmails(folderId: 'inbox');

      expect(emails.map((e) => e.id), ['msg1']);
    });

    // Sent Items copies are what EmailConversation.anchor reads to decide which
    // message heads a thread row, so the expansion must keep surfacing them.
    test('keeps copies from Sent Items and user folders', () async {
      stubMailbox(
        listedFolderId: 'inbox',
        folderPage: [_messageJson('msg1', 'conv-1')],
        conversation: [
          _messageJson('msg1', 'conv-1'),
          _messageJson('my-reply', 'conv-1', parentFolderId: 'AQMk-sent'),
          _messageJson('filed', 'conv-1', parentFolderId: 'AAMk-project'),
        ],
      );

      final emails = await datasource.getEmails(folderId: 'inbox');

      expect(emails.map((e) => e.id), ['msg1', 'my-reply', 'filed']);
    });

    test('keeps its own messages when Deleted Items is the folder being listed',
        () async {
      stubMailbox(
        listedFolderId: deletedItemsId,
        folderPage: [
          _messageJson('deleted1', 'conv-1', parentFolderId: deletedItemsId),
        ],
        conversation: [
          _messageJson('deleted1', 'conv-1', parentFolderId: deletedItemsId),
          _messageJson('deleted2', 'conv-1', parentFolderId: deletedItemsId),
        ],
      );

      final emails = await datasource.getEmails(folderId: deletedItemsId);

      expect(emails.map((e) => e.id), ['deleted1', 'deleted2']);
    });

    // The poller addresses folders by Graph's well-known names, not by id.
    test('recognises the folder addressed by its well-known name', () async {
      stubMailbox(
        listedFolderId: 'deleteditems',
        folderPage: [
          _messageJson('deleted1', 'conv-1', parentFolderId: deletedItemsId),
        ],
        conversation: [
          _messageJson('deleted1', 'conv-1', parentFolderId: deletedItemsId),
        ],
      );

      final emails = await datasource.getEmails(folderId: 'deleteditems');

      expect(emails.map((e) => e.id), ['deleted1']);
      verifyNever(mockDio.get<Map<String, dynamic>>(
        '/me/mailFolders/deleteditems',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      ));
    });

    // A folder listing must not depend on the lookup, and a partial answer must
    // not be cached — otherwise one throttled request expands deleted mail back
    // into the folder for the rest of the session.
    test('lists the folder anyway when the lookup fails, and retries next time',
        () async {
      when(mockDio.get<String>(
        '/me/mailFolders/inbox/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [_messageJson('msg1', 'conv-1')],
          }));
      when(mockDio.get<String>(
        '/me/messages',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => _resp({
            'value': [
              _messageJson('msg1', 'conv-1'),
              _messageJson('deleted', 'conv-1',
                  parentFolderId: deletedItemsId),
            ],
          }));

      var lookupAttempts = 0;
      when(mockDio.get<Map<String, dynamic>>(
        '/me/mailFolders/deleteditems',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async {
        lookupAttempts++;
        if (lookupAttempts == 1) {
          throw DioException(
            type: DioExceptionType.badResponse,
            response: Response(
              statusCode: 429,
              requestOptions: RequestOptions(path: '/me/mailFolders'),
            ),
            requestOptions: RequestOptions(path: '/me/mailFolders'),
          );
        }
        return Response(
          data: const {'id': deletedItemsId},
          statusCode: 200,
          requestOptions: RequestOptions(path: '/me/mailFolders'),
        );
      });
      when(mockDio.get<Map<String, dynamic>>(
        '/me/mailFolders/junkemail',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: const {'id': junkId},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/mailFolders'),
          ));

      final first = await datasource.getEmails(folderId: 'inbox');
      expect(first.map((e) => e.id), ['msg1', 'deleted'],
          reason: 'the listing still answers when the lookup fails');

      final second = await datasource.getEmails(folderId: 'inbox');
      expect(second.map((e) => e.id), ['msg1'],
          reason: 'the failed lookup was not memoised');
      expect(lookupAttempts, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // getEmail — plain-text detection
  //
  // Graph renders every body as HTML unless asked otherwise and reports
  // contentType 'html' either way, so a text/plain message used to reach the
  // reading pane looking like an HTML one and render in the webview.
  // ---------------------------------------------------------------------------

  group('declaresPlainTextBody', () {
    List<dynamic> headers(String name, String value) => [
          {'name': 'Received', 'value': 'from mail.example.com'},
          {'name': name, 'value': value},
        ];

    test('accepts text/plain with a charset parameter', () {
      expect(
        declaresPlainTextBody(
            headers('Content-Type', 'text/plain; charset="utf-8"')),
        isTrue,
      );
    });

    test('matches the header name case-insensitively', () {
      expect(
        declaresPlainTextBody(headers('CONTENT-TYPE', 'TEXT/PLAIN')),
        isTrue,
      );
    });

    test('rejects text/html', () {
      expect(
        declaresPlainTextBody(headers('Content-Type', 'text/html')),
        isFalse,
      );
    });

    // A plain-text message carrying an attachment is multipart/mixed, and the
    // top-level header cannot say which part Graph rendered. Left as HTML
    // rather than guessed at.
    test('rejects multipart, which says nothing about the body part', () {
      expect(
        declaresPlainTextBody(
            headers('Content-Type', 'multipart/alternative; boundary=x')),
        isFalse,
      );
    });

    test('rejects headers that are absent altogether', () {
      expect(declaresPlainTextBody(const []), isFalse);
      expect(declaresPlainTextBody(headers('Subject', 'text/plain')), isFalse);
    });
  });

  group('getEmail — body type', () {
    Map<String, dynamic> fullMessage(String html) => {
          'id': 'msg1',
          'subject': 'Test',
          'from': {
            'emailAddress': {'address': 'a@b.com', 'name': 'A'}
          },
          'toRecipients': <dynamic>[],
          'ccRecipients': <dynamic>[],
          'bodyPreview': 'preview',
          'body': {'contentType': 'html', 'content': html},
          'isRead': true,
          'receivedDateTime': '2026-01-01T00:00:00Z',
          'importance': 'normal',
          'hasAttachments': false,
          'parentFolderId': 'inbox',
        };

    /// Routes the two `/me/messages/msg1` GETs apart by their `$select`: the
    /// probe asks for headers, the message itself asks for nothing.
    void stubMessage({
      required String html,
      Map<String, dynamic>? probeResponse,
      bool probeThrows = false,
      void Function(Options?)? onProbe,
    }) {
      when(mockDio.get<String>(
        '/me/messages/msg1',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((invocation) async {
        final params =
            invocation.namedArguments[#queryParameters] as Map<String, dynamic>?;
        final isProbe = (params?['\$select'] as String?)
                ?.contains('internetMessageHeaders') ??
            false;
        if (!isProbe) return _resp(fullMessage(html));
        onProbe?.call(invocation.namedArguments[#options] as Options?);
        if (probeThrows) {
          throw DioException(
            type: DioExceptionType.badResponse,
            response: Response(
              statusCode: 403,
              requestOptions: RequestOptions(path: '/me/messages/msg1'),
            ),
            requestOptions: RequestOptions(path: '/me/messages/msg1'),
          );
        }
        return _resp(probeResponse ?? const {});
      });
    }

    test('uses the text body and text type when the headers say text/plain',
        () async {
      stubMessage(
        html: '<html><body><div>Line 1<br>Line 2</div></body></html>',
        probeResponse: {
          'internetMessageHeaders': [
            {'name': 'Content-Type', 'value': 'text/plain; charset="utf-8"'}
          ],
          'body': {'contentType': 'text', 'content': 'Line 1\nLine 2'},
        },
      );

      final email = await datasource.getEmail('msg1');

      expect(email.bodyType, EmailBodyType.text);
      expect(email.body, 'Line 1\nLine 2');
    });

    test('keeps the HTML body when the headers say text/html', () async {
      const html = '<html><body><div>Hello</div></body></html>';
      stubMessage(
        html: html,
        probeResponse: {
          'internetMessageHeaders': [
            {'name': 'Content-Type', 'value': 'text/html; charset="utf-8"'}
          ],
          'body': {'contentType': 'text', 'content': 'Hello'},
        },
      );

      final email = await datasource.getEmail('msg1');

      expect(email.bodyType, EmailBodyType.html);
      expect(email.body, html);
    });

    // Exchange does not always keep internet headers for internal mail, and the
    // probe is an extra request that can be throttled. Neither may cost the
    // user the message.
    test('falls back to the HTML body when the probe fails', () async {
      const html = '<html><body><div>Hello</div></body></html>';
      stubMessage(html: html, probeThrows: true);

      final email = await datasource.getEmail('msg1');

      expect(email.bodyType, EmailBodyType.html);
      expect(email.body, html);
    });

    test('falls back to the HTML body when no headers come back', () async {
      const html = '<html><body><div>Hello</div></body></html>';
      stubMessage(html: html, probeResponse: {'id': 'msg1'});

      final email = await datasource.getEmail('msg1');

      expect(email.bodyType, EmailBodyType.html);
      expect(email.body, html);
    });

    test('asks Graph for the text rendition rather than converting the HTML',
        () async {
      Options? probeOptions;
      stubMessage(
        html: '<html><body><div>Hi</div></body></html>',
        probeResponse: {
          'internetMessageHeaders': [
            {'name': 'Content-Type', 'value': 'text/plain'}
          ],
          'body': {'contentType': 'text', 'content': 'Hi'},
        },
        onProbe: (options) => probeOptions = options,
      );

      await datasource.getEmail('msg1');

      expect(probeOptions?.headers?['Prefer'],
          'outlook.body-content-type="text"');
    });
  });
}
