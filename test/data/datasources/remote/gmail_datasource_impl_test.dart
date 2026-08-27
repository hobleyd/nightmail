import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';

import 'gmail_datasource_impl_test.mocks.dart';

String _padBase64(String s) {
  final padding = (4 - s.length % 4) % 4;
  return s + ('=' * padding);
}

/// base64url-encodes (no padding) a UTF-8 string, matching the Gmail payload
/// `body.data` encoding the datasource decodes.
String _b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

/// Returns a base64url-encoded (no padding) minimal raw MIME email.
String _rawMime({
  String from = 'alice@example.com',
  String to = 'me@example.com',
  String subject = 'Test Subject',
  String body = 'Hello',
}) {
  final mime = 'From: $from\r\nTo: $to\r\nSubject: $subject\r\n'
      'MIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\n$body';
  return base64Url.encode(utf8.encode(mime)).replaceAll('=', '');
}

/// Minimal "full" format message JSON for the GET messages/{id}?format=full mock.
Map<String, dynamic> _fullMessage({String subject = 'Test Subject'}) => {
      'threadId': 'thread1',
      'payload': {
        'mimeType': 'text/plain',
        'headers': [
          {'name': 'Subject', 'value': subject},
        ],
        'parts': <dynamic>[],
      },
    };

Response<Map<String, dynamic>> _jsonResp(Map<String, dynamic> data, String path) =>
    Response(data: data, statusCode: 200, requestOptions: RequestOptions(path: path));

/// The undecoded form, for the endpoints requested with `ResponseType.plain`.
Response<String> _plainResp(Map<String, dynamic> data, String path) => Response(
      data: jsonEncode(data),
      statusCode: 200,
      requestOptions: RequestOptions(path: path),
    );

Response<void> _sendResp() => Response<void>(
      statusCode: 200,
      requestOptions: RequestOptions(path: '/users/me/messages/send'),
    );

Response<Map<String, dynamic>> _labelsResp(List<Map<String, dynamic>> labels) =>
    Response(
      data: {'labels': labels},
      statusCode: 200,
      requestOptions: RequestOptions(path: '/users/me/labels'),
    );

Map<String, dynamic> _label(String id, String name, {String type = 'user'}) =>
    {'id': id, 'name': name, 'type': type};

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GmailDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GmailDatasourceImpl.withDio(mockDio);
  });

  void stubLabels(List<Map<String, dynamic>> labels) {
    when(mockDio.get<Map<String, dynamic>>(any)).thenAnswer(
      (_) async => _labelsResp(labels),
    );
  }

  // ---------------------------------------------------------------------------
  // Flat labels — no "/" in name, no hierarchy change
  // ---------------------------------------------------------------------------

  group('getMailFolders — flat labels', () {
    test('maps system label names to display names', () async {
      stubLabels([
        _label('INBOX', 'INBOX', type: 'system'),
        _label('SENT', 'SENT', type: 'system'),
        _label('DRAFT', 'DRAFT', type: 'system'),
        _label('TRASH', 'TRASH', type: 'system'),
        _label('SPAM', 'SPAM', type: 'system'),
      ]);

      final folders = await datasource.getMailFolders();
      final names = folders.map((f) => f.displayName).toList();

      expect(names, containsAll(['Inbox', 'Sent', 'Drafts', 'Trash', 'Spam']));
    });

    test('filters hidden system labels (CHAT, STARRED, IMPORTANT, UNREAD)', () async {
      stubLabels([
        _label('INBOX', 'INBOX', type: 'system'),
        _label('CHAT', 'CHAT', type: 'system'),
        _label('STARRED', 'STARRED', type: 'system'),
        _label('IMPORTANT', 'IMPORTANT', type: 'system'),
        _label('UNREAD', 'UNREAD', type: 'system'),
      ]);

      final folders = await datasource.getMailFolders();
      final ids = folders.map((f) => f.id).toList();

      expect(ids, contains('INBOX'));
      expect(ids, isNot(contains('CHAT')));
      expect(ids, isNot(contains('STARRED')));
      expect(ids, isNot(contains('IMPORTANT')));
      expect(ids, isNot(contains('UNREAD')));
    });

    test('user label with no "/" has null parentFolderId and childFolderCount 0', () async {
      stubLabels([_label('Label_1', 'MyLabel')]);

      final folders = await datasource.getMailFolders();

      expect(folders.length, 1);
      expect(folders.first.displayName, 'MyLabel');
      expect(folders.first.parentFolderId, isNull);
      expect(folders.first.childFolderCount, 0);
    });

    // Regression: the labels list carries no counts, so every label costs a
    // request of its own — and all of them went out at once. On a mailbox with a
    // few dozen labels that was enough for Gmail to close connections
    // mid-header, losing the counts the requests were there to fetch, on every
    // folder-list load.
    test('fetches label counts a bounded number at a time', () async {
      final labels = [
        for (var i = 0; i < 30; i++) _label('Label_$i', 'Label $i'),
      ];
      var inFlight = 0;
      var peakInFlight = 0;
      when(mockDio.get<Map<String, dynamic>>(any)).thenAnswer((inv) async {
        final path = inv.positionalArguments.first as String;
        if (path == '/users/me/labels') return _labelsResp(labels);
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        return _jsonResp({'messagesUnread': 1, 'messagesTotal': 2}, path);
      });

      final folders = await datasource.getMailFolders();

      expect(peakInFlight, lessThanOrEqualTo(8));
      // Bounded, not skipped: every label is still counted.
      expect(folders.length, 30);
      expect(folders.every((f) => f.unreadItemCount == 1), isTrue);
      expect(folders.every((f) => f.totalItemCount == 2), isTrue);
    });

    test('returns empty list when API returns no labels', () async {
      when(mockDio.get<Map<String, dynamic>>(any)).thenAnswer(
        (_) async => Response(
          data: <String, dynamic>{},
          statusCode: 200,
          requestOptions: RequestOptions(path: '/users/me/labels'),
        ),
      );

      expect(await datasource.getMailFolders(), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // "/" hierarchy — the main change
  // ---------------------------------------------------------------------------

  group('getMailFolders — "/" hierarchy', () {
    test('creates virtual parent for a single nested label', () async {
      stubLabels([_label('Label_1', 'HTW/AI Initiatives')]);

      final folders = await datasource.getMailFolders();
      final byId = {for (final f in folders) f.id: f};

      expect(byId, contains('__virtual__HTW'));
      expect(byId['__virtual__HTW']!.displayName, 'HTW');
      expect(byId['__virtual__HTW']!.parentFolderId, isNull);
      expect(byId['__virtual__HTW']!.childFolderCount, 1);

      expect(byId['Label_1']!.displayName, 'AI Initiatives');
      expect(byId['Label_1']!.parentFolderId, '__virtual__HTW');
      expect(byId['Label_1']!.childFolderCount, 0);
    });

    test('creates only one virtual parent for multiple siblings', () async {
      stubLabels([
        _label('Label_1', 'HTW/AI Initiatives'),
        _label('Label_2', 'HTW/Finance'),
      ]);

      final folders = await datasource.getMailFolders();
      final virtualParents = folders.where((f) => f.id == '__virtual__HTW').toList();

      expect(virtualParents.length, 1);
      expect(virtualParents.first.childFolderCount, 2);
    });

    test('uses real label id as parent when a label with that path exists', () async {
      stubLabels([
        _label('Label_HTW', 'HTW'),
        _label('Label_1', 'HTW/AI Initiatives'),
        _label('Label_2', 'HTW/Finance'),
      ]);

      final folders = await datasource.getMailFolders();
      final ids = folders.map((f) => f.id).toList();

      expect(ids, isNot(contains('__virtual__HTW')));

      final ai = folders.firstWhere((f) => f.id == 'Label_1');
      expect(ai.parentFolderId, 'Label_HTW');

      final finance = folders.firstWhere((f) => f.id == 'Label_2');
      expect(finance.parentFolderId, 'Label_HTW');
    });

    test('increments childFolderCount on a real parent label', () async {
      stubLabels([
        _label('Label_HTW', 'HTW'),
        _label('Label_1', 'HTW/AI Initiatives'),
        _label('Label_2', 'HTW/Finance'),
      ]);

      final folders = await datasource.getMailFolders();
      final parent = folders.firstWhere((f) => f.id == 'Label_HTW');

      expect(parent.childFolderCount, 2);
    });

    test('handles three-level hierarchy', () async {
      stubLabels([_label('Label_1', 'A/B/C')]);

      final folders = await datasource.getMailFolders();
      final byId = {for (final f in folders) f.id: f};

      expect(byId, contains('__virtual__A'));
      expect(byId, contains('__virtual__A/B'));
      expect(byId, contains('Label_1'));

      expect(byId['__virtual__A']!.parentFolderId, isNull);
      expect(byId['__virtual__A/B']!.parentFolderId, '__virtual__A');
      expect(byId['Label_1']!.parentFolderId, '__virtual__A/B');
      expect(byId['Label_1']!.displayName, 'C');

      expect(byId['__virtual__A']!.childFolderCount, 1);
      expect(byId['__virtual__A/B']!.childFolderCount, 1);
    });

    test('flat and nested labels coexist correctly', () async {
      stubLabels([
        _label('INBOX', 'INBOX', type: 'system'),
        _label('Label_flat', 'Standalone'),
        _label('Label_1', 'HTW/Finance'),
      ]);

      final folders = await datasource.getMailFolders();
      final byId = {for (final f in folders) f.id: f};

      expect(byId['INBOX']!.parentFolderId, isNull);
      expect(byId['Label_flat']!.parentFolderId, isNull);
      expect(byId['Label_flat']!.childFolderCount, 0);
      expect(byId['__virtual__HTW']!.childFolderCount, 1);
      expect(byId['Label_1']!.parentFolderId, '__virtual__HTW');
    });

    test('two different top-level groups produce independent virtual roots', () async {
      stubLabels([
        _label('Label_1', 'HTW/Finance'),
        _label('Label_2', 'Personal/Travel'),
      ]);

      final folders = await datasource.getMailFolders();
      final byId = {for (final f in folders) f.id: f};

      expect(byId['__virtual__HTW']!.childFolderCount, 1);
      expect(byId['__virtual__Personal']!.childFolderCount, 1);
      expect(byId['Label_1']!.parentFolderId, '__virtual__HTW');
      expect(byId['Label_2']!.parentFolderId, '__virtual__Personal');
    });
  });

  // ---------------------------------------------------------------------------
  // getChildFolders — Gmail labels are always flat from the API side
  // ---------------------------------------------------------------------------

  group('getChildFolders', () {
    test('always returns empty list regardless of id', () async {
      expect(await datasource.getChildFolders('INBOX'), isEmpty);
      expect(await datasource.getChildFolders('Label_1'), isEmpty);
      expect(await datasource.getChildFolders('__virtual__HTW'), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // moveEmail — labels modify API
  // ---------------------------------------------------------------------------

  Response<Map<String, dynamic>> _metaResp(List<String> labelIds) => Response(
        data: {'labelIds': labelIds},
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  Response<void> _modifyResp() => Response(
        data: null,
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  void stubMeta(List<String> labelIds) {
    when(mockDio.get<Map<String, dynamic>>(
      any,
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => _metaResp(labelIds));
  }

  void stubModify() {
    when(mockDio.post<void>(
      any,
      data: anyNamed('data'),
    )).thenAnswer((_) async => _modifyResp());
  }

  group('moveEmail', () {
    test('adds destination label and removes INBOX when moving from inbox', () async {
      stubMeta(['INBOX', 'UNREAD']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_dest');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['Label_dest']);
      expect(captured['removeLabelIds'], contains('INBOX'));
      expect(captured['removeLabelIds'], isNot(contains('UNREAD')));
    });

    test('removes source user label when moving label to label', () async {
      stubMeta(['Label_old', 'UNREAD', 'IMPORTANT']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_new');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['Label_new']);
      expect(captured['removeLabelIds'], contains('Label_old'));
      expect(captured['removeLabelIds'], isNot(contains('UNREAD')));
      expect(captured['removeLabelIds'], isNot(contains('IMPORTANT')));
    });

    test('does not add removeLabelIds when no folder labels present', () async {
      stubMeta(['UNREAD', 'STARRED']);
      stubModify();

      await datasource.moveEmail('msg1', 'INBOX');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['INBOX']);
      expect(captured.containsKey('removeLabelIds'), isFalse);
    });

    test('does not include destination label in removeLabelIds', () async {
      stubMeta(['INBOX', 'Label_dest']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_dest');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      final removed = captured['removeLabelIds'] as List?;
      expect(removed, isNot(contains('Label_dest')));
      expect(removed, contains('INBOX'));
    });

    // A Gmail folder listing is `threads?labelIds=…`, so a thread stays listed
    // in the Inbox with not one of its messages carrying INBOX. The per-message
    // modify has nothing to act on there; the thread endpoint does.
    test('removeConversationFromFolder posts to the thread modify endpoint',
        () async {
      stubModify();

      await datasource.removeConversationFromFolder('thread1', 'INBOX');

      final captured = verify(mockDio.post<void>(
        '/users/me/threads/thread1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['removeLabelIds'], ['INBOX']);
    });

    // Removal only. This reaches the thread's copies in Sent, and adding a
    // destination label to those is exactly what the folder-scoped move's Sent
    // guard exists to prevent — it would file the record of what was sent into
    // the folder the user was tidying.
    test('removeConversationFromFolder never adds a label', () async {
      stubModify();

      await datasource.removeConversationFromFolder('thread1', 'INBOX');

      final captured = verify(mockDio.post<void>(
        any,
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured.containsKey('addLabelIds'), isFalse);
    });

    // It reads no metadata either: there is nothing to diff, and the whole
    // point is that the message-level labels do not mention this folder.
    test('removeConversationFromFolder fetches no metadata first', () async {
      stubModify();

      await datasource.removeConversationFromFolder('thread1', 'INBOX');

      verifyNever(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      ));
    });

    test('fetches message metadata before posting modify', () async {
      stubMeta(['INBOX']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_dest');

      verify(mockDio.get<Map<String, dynamic>>(
        '/users/me/messages/msg1',
        queryParameters: anyNamed('queryParameters'),
      ));
    });

    // Regression: Gmail API returns 400 when removeLabelIds contains SENT.
    // If the whole modify call fails, INBOX stays on the message and the
    // thread reappears in the inbox after a refresh.

    test('does not include SENT in removeLabelIds — Gmail forbids removing it', () async {
      stubMeta(['SENT']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_dest');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['Label_dest']);
      // SENT is the only label and it cannot be removed, so no removeLabelIds key.
      expect(captured.containsKey('removeLabelIds'), isFalse);
    });

    test('removes INBOX but not SENT when message carries both', () async {
      stubMeta(['SENT', 'INBOX']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_dest');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['Label_dest']);
      expect(captured['removeLabelIds'], contains('INBOX'));
      expect(captured['removeLabelIds'], isNot(contains('SENT')));
    });

    test('removes user label but not SENT when message carries both', () async {
      stubMeta(['SENT', 'Label_old']);
      stubModify();

      await datasource.moveEmail('msg1', 'Label_new');

      final captured = verify(mockDio.post<void>(
        '/users/me/messages/msg1/modify',
        data: captureAnyNamed('data'),
      )).captured.single as Map<String, dynamic>;

      expect(captured['addLabelIds'], ['Label_new']);
      expect(captured['removeLabelIds'], contains('Label_old'));
      expect(captured['removeLabelIds'], isNot(contains('SENT')));
    });
  });

  // ---------------------------------------------------------------------------
  // deleteEmail — trash endpoint
  // ---------------------------------------------------------------------------

  Response<void> _trashResp() => Response(
        statusCode: 200,
        requestOptions: RequestOptions(path: ''),
      );

  void stubTrash() {
    when(mockDio.post<void>(any)).thenAnswer((_) async => _trashResp());
  }

  group('createServerDraft', () {
    Response<Map<String, dynamic>> _draftResp(String draftId) => Response(
          data: {'id': draftId},
          statusCode: 200,
          requestOptions: RequestOptions(path: '/users/me/drafts'),
        );

    test('calls POST /users/me/drafts and returns the draft ID', () async {
      when(mockDio.post<Map<String, dynamic>>(
        '/users/me/drafts',
        data: anyNamed('data'),
      )).thenAnswer((_) async => _draftResp('r1234567890'));

      final id = await datasource.createServerDraft(
        toAddresses: ['alice@example.com'],
        subject: 'Hello',
        body: 'World',
      );

      expect(id, equals('r1234567890'));
      verify(mockDio.post<Map<String, dynamic>>(
        '/users/me/drafts',
        data: anyNamed('data'),
      )).called(1);
    });

    test('throws ServerException when response contains no id', () async {
      when(mockDio.post<Map<String, dynamic>>(
        '/users/me/drafts',
        data: anyNamed('data'),
      )).thenAnswer((_) async => Response(
            data: <String, dynamic>{},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/users/me/drafts'),
          ));

      await expectLater(
        datasource.createServerDraft(
          toAddresses: ['alice@example.com'],
          subject: 'Hello',
          body: 'World',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('propagates DioException on network failure', () async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
      ));

      await expectLater(
        datasource.createServerDraft(
          toAddresses: ['alice@example.com'],
          subject: 'Hello',
          body: 'World',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('updateServerDraft', () {
    test('calls PUT /users/me/drafts/{id} and returns the same draft ID',
        () async {
      when(mockDio.put<Map<String, dynamic>>(
        '/users/me/drafts/r1234567890',
        data: anyNamed('data'),
      )).thenAnswer((_) async => Response(
            data: <String, dynamic>{},
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ));

      final id = await datasource.updateServerDraft(
        draftId: 'r1234567890',
        toAddresses: ['alice@example.com'],
        subject: 'Updated',
        body: 'Body',
      );

      expect(id, equals('r1234567890'));
      verify(mockDio.put<Map<String, dynamic>>(
        '/users/me/drafts/r1234567890',
        data: anyNamed('data'),
      )).called(1);
    });

    test('propagates DioException on network failure', () async {
      when(mockDio.put<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
      ));

      await expectLater(
        datasource.updateServerDraft(
          draftId: 'r1234567890',
          toAddresses: ['alice@example.com'],
          subject: 'Updated',
          body: 'Body',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('deleteServerDraft', () {
    test('calls DELETE /users/me/drafts/{id}', () async {
      when(mockDio.delete<void>('/users/me/drafts/r1234567890'))
          .thenAnswer((_) async => Response(
                statusCode: 204,
                requestOptions: RequestOptions(path: ''),
              ));

      await datasource.deleteServerDraft(draftId: 'r1234567890');

      verify(mockDio.delete<void>('/users/me/drafts/r1234567890')).called(1);
    });

    test('propagates DioException on network failure', () async {
      when(mockDio.delete<void>(any)).thenThrow(DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.connectionError,
      ));

      await expectLater(
        datasource.deleteServerDraft(draftId: 'r1234567890'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('deleteEmail', () {
    test('calls the Gmail trash endpoint with the correct message id', () async {
      stubTrash();

      await datasource.deleteEmail('msg42');

      verify(mockDio.post<void>('/users/me/messages/msg42/trash'));
    });

    test('does not call the metadata endpoint before trashing', () async {
      stubTrash();

      await datasource.deleteEmail('msg1');

      verifyNever(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
      ));
    });

    test('propagates DioException on network failure', () async {
      when(mockDio.post<void>(any)).thenAnswer((_) async => throw DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.connectionError,
          ));

      await expectLater(
        datasource.deleteEmail('msg1'),
        throwsA(isA<DioException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // forwardEmail — To and Cc recipients in raw MIME
  // ---------------------------------------------------------------------------

  void _stubGetByUrl(Map<String, dynamic> Function(String url) responder) {
    when(mockDio.get<Map<String, dynamic>>(any)).thenAnswer((inv) async {
      final url = inv.positionalArguments[0] as String;
      return _jsonResp(responder(url), url);
    });
    when(mockDio.get<Map<String, dynamic>>(any,
            queryParameters: anyNamed('queryParameters')))
        .thenAnswer((inv) async {
      final url = inv.positionalArguments[0] as String;
      return _jsonResp(responder(url), url);
    });
    // The message-fetching calls ask for ResponseType.plain so the parse can run
    // on a background isolate, so they arrive as get<String> and are answered
    // with the response still encoded — exactly what the parser isolate gets.
    when(mockDio.get<String>(
      any,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((inv) async {
      final url = inv.positionalArguments[0] as String;
      return _plainResp(responder(url), url);
    });
  }

  group('GmailDatasourceImpl.forwardEmail — To recipients in MIME', () {
    test('sets To header in raw MIME', () async {
      _stubGetByUrl((url) => url.contains('profile')
          ? {'emailAddress': 'me@example.com'}
          : _fullMessage());
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _sendResp());

      await datasource.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['alice@example.com'],
        comment: 'FYI',
      );

      final data = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final rawMime =
          utf8.decode(base64Url.decode(_padBase64(data['raw'] as String)));
      expect(rawMime.toLowerCase(), contains('to: alice@example.com'));
    });
  });

  group('GmailDatasourceImpl.forwardEmail — Cc recipients in MIME', () {
    test('includes Cc header in raw MIME when ccAddresses is non-empty', () async {
      _stubGetByUrl((url) => url.contains('profile')
          ? {'emailAddress': 'me@example.com'}
          : _fullMessage());
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _sendResp());

      await datasource.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        ccAddresses: ['cc@example.com'],
        comment: 'FYI',
      );

      final data = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final rawMime =
          utf8.decode(base64Url.decode(_padBase64(data['raw'] as String)));
      expect(rawMime.toLowerCase(), contains('cc: cc@example.com'));
    });

    test('omits Cc header when ccAddresses is empty', () async {
      _stubGetByUrl((url) => url.contains('profile')
          ? {'emailAddress': 'me@example.com'}
          : _fullMessage());
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _sendResp());

      await datasource.forwardEmail(
        messageId: 'msg1',
        toAddresses: ['to@example.com'],
        comment: 'FYI',
      );

      final data = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final rawMime =
          utf8.decode(base64Url.decode(_padBase64(data['raw'] as String)));
      expect(rawMime.toLowerCase(), isNot(contains('\r\ncc:')));
    });
  });

  // ---------------------------------------------------------------------------
  // replyToEmail — To/Cc in raw MIME, no duplicates
  // ---------------------------------------------------------------------------

  group('GmailDatasourceImpl.replyToEmail — Cc recipients in MIME', () {
    test('includes Cc header in raw MIME when ccAddresses is non-empty', () async {
      _stubGetByUrl((url) => url.contains('profile')
          ? {'emailAddress': 'me@example.com'}
          : {'raw': _rawMime(), 'threadId': 'thread1'});
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _sendResp());

      await datasource.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        toAddresses: ['alice@example.com'],
        ccAddresses: ['cc@example.com'],
      );

      final data = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final rawMime =
          utf8.decode(base64Url.decode(_padBase64(data['raw'] as String)));
      expect(rawMime.toLowerCase(), contains('cc: cc@example.com'));
    });
  });

  group('GmailDatasourceImpl.replyToEmail — To not duplicated', () {
    test('To address appears only once in raw MIME (not duplicated vs prepareReplyToMessage)', () async {
      _stubGetByUrl((url) => url.contains('profile')
          ? {'emailAddress': 'me@example.com'}
          : {'raw': _rawMime(from: 'alice@example.com'), 'threadId': 'thread1'});
      when(mockDio.post<void>(any, data: anyNamed('data')))
          .thenAnswer((_) async => _sendResp());

      await datasource.replyToEmail(
        messageId: 'msg1',
        comment: 'Thanks',
        toAddresses: ['alice@example.com'],
      );

      final data = verify(mockDio.post<void>(any, data: captureAnyNamed('data')))
          .captured.single as Map<String, dynamic>;
      final rawMime =
          utf8.decode(base64Url.decode(_padBase64(data['raw'] as String)));
      // alice@example.com should appear in To exactly once
      final toLineMatches =
          RegExp(r'to:.*alice@example\.com', caseSensitive: false)
              .allMatches(rawMime)
              .length;
      expect(toLineMatches, equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // getEmail — inline (cid:) image resolution
  // ---------------------------------------------------------------------------

  group('GmailDatasourceImpl.getEmail — inline images', () {
    // Regression: Gmail tags pasted inline images with
    // `Content-Disposition: attachment` while still referencing them via cid:
    // in the HTML, and stores the bytes as a separate attachment (no inline
    // data). They must still resolve as inline attachments — here the
    // Content-ID even carries an @-suffix the body reference lacks.
    test('resolves a cid: image tagged attachment with an @-suffixed '
        'Content-ID', () async {
      const html = '<div><img src="cid:ii_x" alt="image.png"></div>';
      final imageBytes = base64Url.encode([1, 2, 3, 4]).replaceAll('=', '');

      _stubGetByUrl((url) {
        if (url.contains('/attachments/')) return {'data': imageBytes};
        return {
          'id': 'msg1',
          'threadId': 'thread1',
          'payload': {
            'mimeType': 'multipart/related',
            'headers': [
              {'name': 'Subject', 'value': 'Inline test'},
              {'name': 'From', 'value': 'alice@example.com'},
            ],
            'parts': [
              {
                'mimeType': 'text/html',
                'body': {'data': _b64(html), 'size': html.length},
              },
              {
                'mimeType': 'image/png',
                'filename': 'image.png',
                'headers': [
                  {
                    'name': 'Content-Disposition',
                    'value': 'attachment; filename="image.png"',
                  },
                  {'name': 'Content-ID', 'value': '<ii_x@mail.gmail.com>'},
                ],
                'body': {'attachmentId': 'att1', 'size': 1234},
              },
            ],
          },
        };
      });

      final email = await datasource.getEmail('msg1');

      expect(email.inlineAttachments, hasLength(1));
      expect(email.inlineAttachments.first.contentType, 'image/png');
      expect(email.inlineAttachments.first.contentBytes, equals([1, 2, 3, 4]));
      // Shown inline, so not surfaced as a downloadable attachment chip.
      expect(email.attachments, isEmpty);
    });

    // Regression guard: a part carrying a Content-ID that the body does NOT
    // reference is a genuine attachment and must stay downloadable, not be
    // hidden as a (broken, unreferenced) inline image.
    test('a Content-ID part unreferenced by the body stays a normal '
        'attachment', () async {
      const html = '<div>no inline images here</div>';

      _stubGetByUrl((url) {
        if (url.contains('/attachments/')) {
          return {'data': base64Url.encode([1]).replaceAll('=', '')};
        }
        return {
          'id': 'msg1',
          'threadId': 'thread1',
          'payload': {
            'mimeType': 'multipart/mixed',
            'headers': [
              {'name': 'Subject', 'value': 'Attachment test'},
            ],
            'parts': [
              {
                'mimeType': 'text/html',
                'body': {'data': _b64(html), 'size': html.length},
              },
              {
                'mimeType': 'image/png',
                'filename': 'logo.png',
                'headers': [
                  {
                    'name': 'Content-Disposition',
                    'value': 'attachment; filename="logo.png"',
                  },
                  {'name': 'Content-ID', 'value': '<ii_unref>'},
                ],
                'body': {'attachmentId': 'att9', 'size': 10},
              },
            ],
          },
        };
      });

      final email = await datasource.getEmail('msg1');

      expect(email.inlineAttachments, isEmpty);
      expect(email.attachments, hasLength(1));
      expect(email.attachments.first.name, 'logo.png');
    });
  });

  // ---------------------------------------------------------------------------
  // getEmail — iCalendar METHOD classification
  // ---------------------------------------------------------------------------

  group('GmailDatasourceImpl.getEmail — meeting invite type', () {
    String ics(String method, {String dtstart = '20260805T013000Z'}) =>
        'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'METHOD:$method\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:evt-1@example.com\r\n'
        'SUMMARY:Quarterly review\r\n'
        'ORGANIZER;CN="Me":mailto:me@example.com\r\n'
        'DTSTART:$dtstart\r\n'
        'DTEND:20260805T020000Z\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR';

    void stubIcsMessage(String icsText) {
      _stubGetByUrl((url) => {
            'id': 'msg1',
            'threadId': 'thread1',
            'payload': {
              'mimeType': 'multipart/mixed',
              'headers': [
                {'name': 'Subject', 'value': 'Quarterly review'},
                {'name': 'From', 'value': 'bob@example.com'},
              ],
              'parts': [
                {
                  'mimeType': 'text/plain',
                  'body': {'data': _b64('see attached'), 'size': 12},
                },
                {
                  'mimeType': 'text/calendar',
                  'filename': 'counter.ics',
                  'body': {'data': _b64(icsText), 'size': icsText.length},
                },
              ],
            },
          });
    }

    test('classifies METHOD:COUNTER as a proposed new time', () async {
      // An attendee proposing a different time for a meeting we organize. Left
      // as `invitation`, the organizer was offered Accept/Decline/Propose on
      // their own meeting instead of a way to act on the proposal.
      stubIcsMessage(ics('COUNTER'));

      final email = await datasource.getEmail('msg1');

      final invite = email.meetingInvite!;
      expect(invite.type, MeetingEmailType.proposedNewTime);
      expect(invite.uid, 'evt-1@example.com');
      // A counter states only the proposed time, so DTSTART/DTEND *are* it.
      expect(invite.proposedStart, DateTime.utc(2026, 8, 5, 1, 30));
      expect(invite.proposedEnd, DateTime.utc(2026, 8, 5, 2, 0));
    });

    test('classifies METHOD:REQUEST as an invitation with no proposal',
        () async {
      stubIcsMessage(ics('REQUEST'));

      final email = await datasource.getEmail('msg1');

      expect(email.meetingInvite!.type, MeetingEmailType.invitation);
      expect(email.meetingInvite!.proposedStart, isNull);
    });

    test('classifies METHOD:CANCEL as a cancellation', () async {
      stubIcsMessage(ics('CANCEL'));

      final email = await datasource.getEmail('msg1');

      expect(email.meetingInvite!.type, MeetingEmailType.cancellation);
      expect(email.meetingInvite!.proposedStart, isNull);
    });

    test('classifies METHOD:REPLY as a response notification', () async {
      // Google attaches the RSVP as invite.ics to the "Accepted: ..." mail the
      // organizer receives. Left as `invitation`, they were offered
      // Accept/Decline/Propose on their own meeting.
      stubIcsMessage(ics('REPLY'));

      final email = await datasource.getEmail('msg1');

      expect(email.meetingInvite!.type, MeetingEmailType.responseNotification);
      expect(email.meetingInvite!.proposedStart, isNull);
    });

    test('classifies METHOD:PUBLISH as a published event, title and all',
        () async {
      // An event sent as information — a booking, a ticket, a fixture list.
      // The banner creates the event from scratch, so unlike every other type
      // the ICS has to yield a title and a body, not just times.
      stubIcsMessage(
        'BEGIN:VCALENDAR\r\n'
        'METHOD:PUBLISH\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:pub-1@example.com\r\n'
        r'SUMMARY:Rehearsal\, Hall B' '\r\n'
        r'DESCRIPTION:Bring a music stand.\nDoors at 6.' '\r\n'
        'LOCATION:Hall B\r\n'
        'DTSTART:20260805T013000Z\r\n'
        'DTEND:20260805T020000Z\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR',
      );

      final invite = (await datasource.getEmail('msg1')).meetingInvite!;

      expect(invite.type, MeetingEmailType.publishedEvent);
      expect(invite.summary, 'Rehearsal, Hall B');
      expect(invite.description, 'Bring a music stand.\nDoors at 6.');
      expect(invite.location, 'Hall B');
      expect(invite.meetingStart, DateTime.utc(2026, 8, 5, 1, 30));
    });

    test('carries no title for the types that act on an existing meeting',
        () async {
      stubIcsMessage(ics('REQUEST'));

      final invite = (await datasource.getEmail('msg1')).meetingInvite!;

      expect(invite.summary, isNull);
      expect(invite.description, isNull);
    });

    test('classifies a declining METHOD:REPLY as a response notification too',
        () async {
      // Not `declineNotification`: that banner offers "Cancel meeting", which
      // Google's datasource cannot serve from a message id.
      stubIcsMessage(ics('REPLY').replaceFirst(
        'UID:evt-1@example.com',
        'UID:evt-1@example.com\r\n'
            'ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com',
      ));

      final email = await datasource.getEmail('msg1');

      expect(email.meetingInvite!.type, MeetingEmailType.responseNotification);
    });
  });

  // ---------------------------------------------------------------------------
  // getEmails — which folders each message belongs to
  // ---------------------------------------------------------------------------

  // A Gmail folder listing is a *thread* listing: every message of a matching
  // thread comes back whatever labels it carries. Reporting each message's
  // labels is what lets a folder-scoped action — deleting a thread out of the
  // Inbox — tell the messages this folder holds from the sent copies and
  // already-filed replies that merely came along for context.
  group('GmailDatasourceImpl.getEmails — folder membership', () {
    Map<String, dynamic> message(String id, List<String> labelIds) => {
          'id': id,
          'threadId': 'thread1',
          'labelIds': labelIds,
          'internalDate': '1780000000000',
          'payload': {
            'mimeType': 'text/plain',
            'headers': [
              {'name': 'Subject', 'value': 'Re: hello'},
              {'name': 'From', 'value': 'alice@example.com'},
            ],
            'parts': <dynamic>[],
          },
        };

    void stubThread(List<Map<String, dynamic>> messages) {
      _stubGetByUrl((url) => url.endsWith('/threads')
          ? {
              'threads': [
                {'id': 'thread1'},
              ],
            }
          : {'messages': messages});
    }

    test('reports every label the message carries', () async {
      stubThread([
        message('m1', ['INBOX', 'UNREAD', 'Label_7']),
      ]);

      final emails = await datasource.getEmails(folderId: 'INBOX');

      expect(emails, hasLength(1));
      expect(emails.first.folderIds, ['INBOX', 'Label_7'],
          reason: 'UNREAD is a flag, not a folder anyone can view');
      expect(emails.first.isInFolder('Label_7'), isTrue);
    });

    // The bug: a sent reply carries neither INBOX nor any user label, so it has
    // no parentFolderId at all — and a null one used to read as "came from the
    // folder query", putting it in range of a delete aimed at the Inbox.
    test('a sent reply belongs to SENT, not the folder being listed', () async {
      stubThread([
        message('m1', ['INBOX']),
        message('sent1', ['SENT']),
      ]);

      final emails = await datasource.getEmails(folderId: 'INBOX');
      final sent = emails.firstWhere((e) => e.id == 'sent1');

      expect(sent.parentFolderId, isNull);
      expect(sent.folderIds, ['SENT']);
      expect(sent.isInFolder('INBOX'), isFalse);
      expect(sent.isDeletableFrom('INBOX'), isFalse);
      expect(emails.firstWhere((e) => e.id == 'm1').isDeletableFrom('INBOX'),
          isTrue);
    });

    // Membership has to name the same ids getMailFolders() exposes, or a
    // containment check against the folder on screen can never match.
    test('drops the hidden system labels that are not folders', () async {
      stubThread([
        message('m1', ['INBOX', 'STARRED', 'IMPORTANT', 'CHAT', 'UNREAD']),
      ]);

      final emails = await datasource.getEmails(folderId: 'INBOX');

      expect(emails.first.folderIds, ['INBOX']);
    });

    test('a filed reply belongs to its label, not the folder being listed',
        () async {
      stubThread([
        message('m1', ['INBOX']),
        message('filed1', ['Label_Archive']),
      ]);

      final emails = await datasource.getEmails(folderId: 'INBOX');
      final filed = emails.firstWhere((e) => e.id == 'filed1');

      expect(filed.folderIds, ['Label_Archive']);
      expect(filed.isDeletableFrom('INBOX'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // syncMailDelta — users.history.list
  // ---------------------------------------------------------------------------

  // Change detection for a Gmail account used to be a comparison of two
  // integers, so a message read and another arriving unread in the same interval
  // cancelled out and were invisible for good — the baselines were overwritten
  // afterwards, making the missed state the new truth. These lock in that the
  // history feed reports each of those changes on its own.
  group('GmailDatasourceImpl.syncMailDelta', () {
    late List<Map<String, dynamic>> historyQueries;

    setUp(() => historyQueries = []);

    Map<String, dynamic> metaMessage(
      String id, {
      List<String> labelIds = const ['INBOX'],
      String subject = 'Hello',
    }) =>
        {
          'id': id,
          'threadId': 'thread-$id',
          'labelIds': labelIds,
          'internalDate': '1780000000000',
          'payload': {
            'mimeType': 'text/plain',
            'headers': [
              {'name': 'Subject', 'value': subject},
              {'name': 'From', 'value': 'alice@example.com'},
            ],
            'parts': <dynamic>[],
          },
        };

    Map<String, dynamic> page(
      List<Map<String, dynamic>> records, {
      String historyId = '5100',
      String? nextPageToken,
    }) =>
        {
          'historyId': historyId,
          if (records.isNotEmpty) 'history': records,
          if (nextPageToken != null) 'nextPageToken': nextPageToken,
        };

    /// Answers the profile, the history pages (one per call, in order) and the
    /// per-message metadata fetches — all as `get<String>` with the response
    /// still encoded, which is what the parser isolate gets. One response type
    /// throughout on purpose: Mockito cannot tell `get<Map>` from `get<String>`,
    /// and `anyNamed` matches an absent named argument, so a second shape here
    /// would answer the profile with a `Response<String>` cast to Map.
    void stubHistory(
      List<Map<String, dynamic>> pages, {
      String profileHistoryId = '5000',
      Map<String, dynamic> Function(String id)? message,
    }) {
      var pageIndex = 0;
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final url = inv.positionalArguments[0] as String;
        if (url == '/users/me/profile') {
          return _plainResp(
            {'emailAddress': 'me@example.com', 'historyId': profileHistoryId},
            url,
          );
        }
        if (url == '/users/me/history') {
          historyQueries.add(inv.namedArguments[const Symbol('queryParameters')]
              as Map<String, dynamic>);
          final body = pages[pageIndex.clamp(0, pages.length - 1)];
          pageIndex++;
          return _plainResp(body, url);
        }
        final id = url.split('/').last;
        return _plainResp((message ?? metaMessage)(id), url);
      });
    }

    test('seeds the cursor from the profile and fetches nothing', () async {
      stubHistory([page([])], profileHistoryId: '4242');

      final result = await datasource.syncMailDelta('inbox');

      expect(result.deltaLink, '4242');
      expect(result.hasChanges, isFalse);
      expect(historyQueries, isEmpty,
          reason: 'a history stream can only start from a historyId');
    });

    test('asks for every folder-affecting change and does not filter by label',
        () async {
      stubHistory([page([])]);

      await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(historyQueries.single['startHistoryId'], '5000');
      expect(historyQueries.single['historyTypes'], [
        'messageAdded',
        'messageDeleted',
        'labelAdded',
        'labelRemoved',
      ]);
      // A message that has just *lost* INBOX no longer matches labelId=INBOX, so
      // filtering server-side would hide exactly the moves this exists to see.
      expect(historyQueries.single.containsKey('labelId'), isFalse);
    });

    test('advances the cursor and reports nothing when nothing changed',
        () async {
      stubHistory([page([], historyId: '5300')]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.deltaLink, '5300');
      expect(result.hasChanges, isFalse);
    });

    test('a message added to the inbox comes back as an upsert', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              {'message': {'id': 'm1', 'labelIds': ['INBOX', 'UNREAD']}},
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.upserted.map((e) => e.id), ['m1']);
      expect(result.upserted.single.subject, 'Hello');
      expect(result.removedIds, isEmpty);
      expect(result.movedOutIds, isEmpty);
    });

    test('a message added to another folder is ignored', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              {'message': {'id': 'm1', 'labelIds': ['SENT']}},
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.hasChanges, isFalse);
    });

    // The half of the offsetting pair the counts could never see: a message
    // read elsewhere leaves total unchanged and unread down by one, which the
    // arrival of another unread message cancels out exactly.
    test('a message read elsewhere comes back as an upsert', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'labelsRemoved': [
              {
                'message': {'id': 'm1', 'labelIds': ['INBOX']},
                'labelIds': ['UNREAD'],
              },
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.upserted.map((e) => e.id), ['m1']);
      expect(result.upserted.single.isRead, isTrue);
    });

    test('a message moved into the inbox is an upsert, not a bare id', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'labelsAdded': [
              {
                'message': {'id': 'm1', 'labelIds': ['INBOX']},
                'labelIds': ['INBOX'],
              },
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.upserted.map((e) => e.id), ['m1'],
          reason: 'the row the folder shows is not in the history record');
    });

    test('losing the folder label is a move-out, not a delete', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'labelsRemoved': [
              {
                'message': {'id': 'm1', 'labelIds': ['Label_7']},
                'labelIds': ['INBOX'],
              },
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.movedOutIds, ['m1']);
      expect(result.removedIds, isEmpty);
      expect(result.upserted, isEmpty);
    });

    test('being trashed is a move-out', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'labelsAdded': [
              {
                'message': {'id': 'm1', 'labelIds': ['INBOX', 'TRASH']},
                'labelIds': ['TRASH'],
              },
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.movedOutIds, ['m1']);
      expect(result.upserted, isEmpty);
    });

    test('a permanent delete is a removal', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesDeleted': [
              {'message': {'id': 'm1', 'labelIds': ['INBOX']}},
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.removedIds, ['m1']);
      expect(result.movedOutIds, isEmpty);
    });

    test('the last record for a message wins', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              {'message': {'id': 'm1', 'labelIds': ['INBOX', 'UNREAD']}},
            ],
          },
          {
            'id': '5002',
            'labelsAdded': [
              {
                'message': {'id': 'm1', 'labelIds': ['INBOX', 'TRASH']},
                'labelIds': ['TRASH'],
              },
            ],
          },
        ]),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.movedOutIds, ['m1']);
      expect(result.upserted, isEmpty,
          reason: 'arrived and was trashed inside one page');
    });

    test('pages to completion and carries the page token', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              {'message': {'id': 'm1', 'labelIds': ['INBOX']}},
            ],
          },
        ], nextPageToken: 'tok2'),
        page([
          {
            'id': '5002',
            'messagesAdded': [
              {'message': {'id': 'm2', 'labelIds': ['INBOX']}},
            ],
          },
        ], historyId: '5400'),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(historyQueries, hasLength(2));
      expect(historyQueries.first.containsKey('pageToken'), isFalse);
      expect(historyQueries[1]['pageToken'], 'tok2');
      expect(result.upserted.map((e) => e.id).toSet(), {'m1', 'm2'});
      expect(result.deltaLink, '5400');
    });

    test('a walk cut short by the page budget resumes from the last record',
        () async {
      // Every page hands back a token, so the budget is what ends the walk. The
      // cursor then has to be the last record read: the mailbox's current
      // historyId means "now", so storing that would skip everything the walk
      // did not reach, permanently.
      stubHistory([
        for (var i = 1; i <= 10; i++)
          page([
            {
              'id': '60${i.toString().padLeft(2, '0')}',
              'messagesAdded': [
                {'message': {'id': 'm$i', 'labelIds': ['INBOX']}},
              ],
            },
          ], historyId: '9999', nextPageToken: 'tok$i'),
      ]);

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(historyQueries, hasLength(10));
      expect(result.deltaLink, '6010');
      expect(result.upserted, hasLength(10));
    });

    test('too much changed is fatal rather than quietly truncated', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              for (var i = 0; i < 251; i++)
                {'message': {'id': 'm$i', 'labelIds': ['INBOX']}},
            ],
          },
        ]),
      ]);

      await expectLater(
        datasource.syncMailDelta('inbox', deltaLink: '5000'),
        // No status code, which the poller treats as "drop the cursor and
        // re-bootstrap" — the one recovery that does not lose changes. Fetching
        // several hundred messages is not worth it and dropping the surplus
        // while the cursor advances past it is the bug this path removes.
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', isNull)),
      );
    });

    test('an expired startHistoryId is a 404 the poller can recover from',
        () async {
      when(mockDio.get<String>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => throw DioException(
            requestOptions: RequestOptions(path: '/users/me/history'),
            response: Response(
              statusCode: 404,
              requestOptions: RequestOptions(path: '/users/me/history'),
            ),
          ));

      await expectLater(
        datasource.syncMailDelta('inbox', deltaLink: '1'),
        throwsA(isA<ServerException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('a message whose re-fetch fails is skipped, not fatal', () async {
      stubHistory([
        page([
          {
            'id': '5001',
            'messagesAdded': [
              {'message': {'id': 'm1', 'labelIds': ['INBOX']}},
              {'message': {'id': 'm2', 'labelIds': ['INBOX']}},
            ],
          },
        ]),
      ]);
      // Re-stub the message fetch for m1 only; m2's fetch throws.
      when(mockDio.get<String>(
        '/users/me/messages/m2',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => throw DioException(
            requestOptions: RequestOptions(path: '/users/me/messages/m2'),
            type: DioExceptionType.connectionError,
          ));

      final result = await datasource.syncMailDelta('inbox', deltaLink: '5000');

      expect(result.upserted.map((e) => e.id), ['m1']);
    });
  });
}
