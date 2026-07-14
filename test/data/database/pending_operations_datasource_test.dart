// PendingOperations schema test (v10), following the round-trip pattern in
// reminder_schedule_local_datasource_test.dart: opens AppDatabase on an
// in-memory NativeDatabase (runs onCreate -> createAll()) and round-trips
// rows through the AppDatabase's PendingOperationsDatasource implementation.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('PendingOperations (v10)', () {
    test('enqueue then getPendingOperations round-trips, oldest first',
        () async {
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'email1',
        opType: PendingOperationType.markRead,
        payload: '{"isRead":true}',
      );
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'email1',
        folderId: 'folder2',
        opType: PendingOperationType.move,
        payload: '{"destinationFolderId":"folder2"}',
      );

      final ops = await db.getPendingOperations('acct1');
      expect(ops, hasLength(2));
      expect(ops[0].opType, PendingOperationType.markRead);
      expect(ops[1].opType, PendingOperationType.move);
      expect(ops[1].folderId, 'folder2');
      expect(ops.every((o) => o.accountId == 'acct1'), isTrue);
    });

    test('getPendingOperations only returns rows for the given account',
        () async {
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'email1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      await db.enqueue(
        accountId: 'acct2',
        emailId: 'email2',
        opType: PendingOperationType.delete,
        payload: '{}',
      );

      final ops = await db.getPendingOperations('acct1');
      expect(ops, hasLength(1));
      expect(ops.single.emailId, 'email1');
    });

    test('remapEmailId rewrites every queued op for the old id', () async {
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'old-id',
        opType: PendingOperationType.move,
        payload: '{}',
      );
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'old-id',
        opType: PendingOperationType.markRead,
        payload: '{"isRead":true}',
      );

      await db.remapEmailId(
        accountId: 'acct1',
        oldEmailId: 'old-id',
        newEmailId: 'new-id',
      );

      final ops = await db.getPendingOperations('acct1');
      expect(ops, hasLength(2));
      expect(ops.every((o) => o.emailId == 'new-id'), isTrue);
    });

    test('removeOperation deletes only that row', () async {
      final id1 = await db.enqueue(
        accountId: 'acct1',
        emailId: 'email1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      await db.enqueue(
        accountId: 'acct1',
        emailId: 'email2',
        opType: PendingOperationType.delete,
        payload: '{}',
      );

      await db.removeOperation(id1);

      final ops = await db.getPendingOperations('acct1');
      expect(ops, hasLength(1));
      expect(ops.single.emailId, 'email2');
    });

    test('recordFailure increments retryCount and stores the error',
        () async {
      final id = await db.enqueue(
        accountId: 'acct1',
        emailId: 'email1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );

      await db.recordFailure(id: id, error: 'throttled');
      await db.recordFailure(id: id, error: 'throttled again');

      final ops = await db.getPendingOperations('acct1');
      expect(ops.single.retryCount, 2);
      expect(ops.single.lastError, 'throttled again');
    });
  });
}
