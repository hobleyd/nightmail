import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';

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
}
