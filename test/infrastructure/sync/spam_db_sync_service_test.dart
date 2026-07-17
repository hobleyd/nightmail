import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/spam_db_sync_datasource.dart';
import 'package:nightmail/domain/repositories/spam_filter_repository.dart';
import 'package:nightmail/infrastructure/sync/spam_db_sync_service.dart';

import 'spam_db_sync_service_test.mocks.dart';

const _accountId = 'acct-1';

PendingOperationRecord _pendingOp(PendingOperationType opType) =>
    PendingOperationRecord(
      id: 1,
      accountId: _accountId,
      emailId: '__spamdb__',
      folderId: null,
      opType: opType,
      payload: '{}',
      createdAtMs: 0,
      retryCount: 0,
      lastError: null,
    );

@GenerateMocks([
  SpamDbSyncDatasource,
  SpamFilterRepository,
  PendingOperationsDatasource,
])
void main() {
  late MockSpamDbSyncDatasource mockDs;
  late MockSpamFilterRepository mockRepo;
  late MockPendingOperationsDatasource mockPendingOperations;
  late SpamDbSyncService service;

  setUp(() {
    mockDs = MockSpamDbSyncDatasource();
    mockRepo = MockSpamFilterRepository();
    mockPendingOperations = MockPendingOperationsDatasource();
    service = SpamDbSyncService(
      spamFilterRepository: mockRepo,
      pendingOperations: mockPendingOperations,
    );
  });

  group('pullForAccount', () {
    test('does nothing when the server has no SPAMDB message yet', () async {
      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => null);

      await service.pullForAccount(_accountId, mockDs);

      verifyNever(mockDs.downloadSpamDbPayload());
      verifyNever(mockRepo.importState(any, any));
    });

    test('skips the download when the version is unchanged since the last pull',
        () async {
      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => 3);
      final payload =
          base64.encode(utf8.encode(jsonEncode({'totalSpam': 1})));
      when(mockDs.downloadSpamDbPayload()).thenAnswer((_) async => payload);
      when(mockRepo.importState(any, any)).thenAnswer((_) async {});

      await service.pullForAccount(_accountId, mockDs); // first pull: applies v3
      await service.pullForAccount(_accountId, mockDs); // second pull: still v3

      verify(mockDs.downloadSpamDbPayload()).called(1);
      verify(mockRepo.importState(_accountId, any)).called(1);
    });

    test('downloads and imports when the remote version has advanced',
        () async {
      final state = {'totalSpam': 5, 'totalHam': 2};
      final payload = base64.encode(utf8.encode(jsonEncode(state)));
      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => 1);
      when(mockDs.downloadSpamDbPayload()).thenAnswer((_) async => payload);
      when(mockRepo.importState(any, any)).thenAnswer((_) async {});
      await service.pullForAccount(_accountId, mockDs);

      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => 2);
      final newPayload =
          base64.encode(utf8.encode(jsonEncode({'totalSpam': 9})));
      when(mockDs.downloadSpamDbPayload())
          .thenAnswer((_) async => newPayload);
      await service.pullForAccount(_accountId, mockDs);

      verify(mockDs.downloadSpamDbPayload()).called(2);
      final captured = verify(mockRepo.importState(_accountId, captureAny))
          .captured;
      expect(captured.last, {'totalSpam': 9});
    });
  });

  group('pushForAccount', () {
    test('reads the current server version fresh and pushes version + 1',
        () async {
      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => 4);
      when(mockRepo.exportState(_accountId))
          .thenAnswer((_) async => {'totalSpam': 7});
      when(mockDs.pushSpamDb(
        version: anyNamed('version'),
        payload: anyNamed('payload'),
      )).thenAnswer((_) async {});

      await service.pushForAccount(_accountId, mockDs);

      final captured = verify(mockDs.pushSpamDb(
        version: captureAnyNamed('version'),
        payload: captureAnyNamed('payload'),
      )).captured;
      expect(captured[0], 5);
      final decoded =
          jsonDecode(utf8.decode(base64.decode(captured[1] as String)));
      expect(decoded, {'totalSpam': 7});
    });

    test('pushes version 1 when SPAMDB does not exist yet', () async {
      when(mockDs.peekSpamDbVersion()).thenAnswer((_) async => null);
      when(mockRepo.exportState(_accountId)).thenAnswer((_) async => {});
      when(mockDs.pushSpamDb(
        version: anyNamed('version'),
        payload: anyNamed('payload'),
      )).thenAnswer((_) async {});

      await service.pushForAccount(_accountId, mockDs);

      verify(mockDs.pushSpamDb(version: 1, payload: anyNamed('payload')))
          .called(1);
    });

    test('swallows errors from the datasource without throwing', () async {
      when(mockDs.peekSpamDbVersion()).thenThrow(Exception('network error'));

      await expectLater(
          service.pushForAccount(_accountId, mockDs), completes);
    });
  });

  group('enqueuePush', () {
    test('queues a spamDbPush pending op', () async {
      when(mockPendingOperations.getPendingOperations(_accountId))
          .thenAnswer((_) async => []);
      when(mockPendingOperations.enqueue(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        opType: anyNamed('opType'),
        payload: anyNamed('payload'),
      )).thenAnswer((_) async => 1);

      await service.enqueuePush(_accountId);

      verify(mockPendingOperations.enqueue(
        accountId: _accountId,
        emailId: anyNamed('emailId'),
        opType: PendingOperationType.spamDbPush,
        payload: anyNamed('payload'),
      )).called(1);
    });

    test('does not queue a second push while one is already pending',
        () async {
      when(mockPendingOperations.getPendingOperations(_accountId))
          .thenAnswer((_) async => [_pendingOp(PendingOperationType.spamDbPush)]);

      await service.enqueuePush(_accountId);

      verifyNever(mockPendingOperations.enqueue(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        opType: anyNamed('opType'),
        payload: anyNamed('payload'),
      ));
    });
  });
}
