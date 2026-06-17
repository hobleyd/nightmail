import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/gmail_datasource_impl.dart';

import 'gmail_datasource_impl_test.mocks.dart';

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
}
