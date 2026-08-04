// Drift round-trip tests for the calendar outbox queue.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/pending_calendar_operations_datasource.dart';

void main() {
  late AppDatabase db;
  late PendingCalendarOperationsDatasource ds;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ds = db;
  });

  tearDown(() => db.close());

  test('round-trips a queued operation', () async {
    await ds.enqueueCalendarOperation(
      accountId: 'acc1',
      targetId: 'event-1',
      opType: PendingCalendarOperationType.declineEvent,
      payload: '{}',
    );

    final ops = await ds.getPendingCalendarOperations('acc1');
    expect(ops, hasLength(1));
    expect(ops.single.targetId, 'event-1');
    expect(ops.single.opType, PendingCalendarOperationType.declineEvent);
    expect(ops.single.retryCount, 0);
    expect(ops.single.lastError, isNull);
  });

  test('returns operations oldest-first', () async {
    for (final id in ['a', 'b', 'c']) {
      await ds.enqueueCalendarOperation(
        accountId: 'acc1',
        targetId: id,
        opType: PendingCalendarOperationType.cancelEvent,
        payload: '{}',
      );
    }

    final ops = await ds.getPendingCalendarOperations('acc1');
    // Ordered by createdAtMs, with the autoincrement id breaking ties within
    // the same millisecond — either way the queue order is the insert order.
    expect(ops.map((o) => o.targetId), ['a', 'b', 'c']);
  });

  test('operations are scoped to their account', () async {
    await ds.enqueueCalendarOperation(
      accountId: 'acc1',
      targetId: 'mine',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );
    await ds.enqueueCalendarOperation(
      accountId: 'acc2',
      targetId: 'theirs',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );

    expect((await ds.getPendingCalendarOperations('acc1')).single.targetId,
        'mine');
    expect((await ds.getPendingCalendarOperations('acc2')).single.targetId,
        'theirs');
  });

  test('removeCalendarOperation dequeues one operation', () async {
    final id = await ds.enqueueCalendarOperation(
      accountId: 'acc1',
      targetId: 'event-1',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );

    await ds.removeCalendarOperation(id);

    expect(await ds.getPendingCalendarOperations('acc1'), isEmpty);
  });

  test('recordCalendarOperationFailure counts up and keeps the reason',
      () async {
    final id = await ds.enqueueCalendarOperation(
      accountId: 'acc1',
      targetId: 'event-1',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );

    await ds.recordCalendarOperationFailure(id: id, error: 'boom');
    await ds.recordCalendarOperationFailure(id: id, error: 'boom again');

    final op = (await ds.getPendingCalendarOperations('acc1')).single;
    expect(op.retryCount, 2);
    expect(op.lastError, 'boom again');
  });

  test('recording a failure for an operation already dequeued is a no-op',
      () async {
    // The drain can race its own retry backstop; this must not throw.
    await ds.recordCalendarOperationFailure(id: 999, error: 'gone');
    expect(await ds.getPendingCalendarOperations('acc1'), isEmpty);
  });

  test('clearCalendarOperationsForAccount leaves other accounts alone',
      () async {
    await ds.enqueueCalendarOperation(
      accountId: 'acc1',
      targetId: 'mine',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );
    await ds.enqueueCalendarOperation(
      accountId: 'acc2',
      targetId: 'theirs',
      opType: PendingCalendarOperationType.cancelEvent,
      payload: '{}',
    );

    await ds.clearCalendarOperationsForAccount('acc1');

    expect(await ds.getPendingCalendarOperations('acc1'), isEmpty);
    expect(await ds.getPendingCalendarOperations('acc2'), hasLength(1));
  });
}
