import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/commitment_local_datasource.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';

// Bypasses secure-storage platform channels — these tests need round-trip
// fidelity, not real encryption.
class _PlaintextEncryption extends CacheEncryptionService {
  _PlaintextEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async => plaintext;

  @override
  Future<String> decrypt(String stored) async => stored;
}

void main() {
  late AppDatabase db;
  late CommitmentLocalDatasourceImpl ds;

  final now = DateTime(2026, 10, 2, 9);

  Commitment commitment({
    String id = 'iOwe:e1',
    String account = 'acc',
    String emailId = 'e1',
    CommitmentKind kind = CommitmentKind.iOwe,
    CommitmentStatus status = CommitmentStatus.open,
    DateTime? emailDate,
  }) {
    return Commitment(
      id: id,
      accountId: account,
      emailId: emailId,
      conversationId: 'conv',
      kind: kind,
      status: status,
      counterpart: const EmailAddress(address: 'sarah@client.com', name: 'Sarah'),
      subject: 'Migration numbers',
      snippet: "I'll send the numbers today.",
      due: CommitmentDue.today,
      urgency: 2,
      confidence: 0.91,
      emailDate: emailDate ?? now,
      detectedAt: now,
    );
  }

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ds = CommitmentLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
    );
  });

  tearDown(() => db.close());

  test('schema v18 creates the commitment tables', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(19));
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('commitments', 'commitment_scans')",
    ).get();
    expect(
      rows.map((r) => r.data['name']).toSet(),
      {'commitments', 'commitment_scans'},
    );
  });

  test('round-trips a commitment through the encrypted blob', () async {
    final c = commitment();
    await ds.upsertCommitments([c]);

    final back = await ds.getCommitments('acc');
    expect(back, [c]);
    // Who/what live in the blob, not in plaintext columns.
    final row = await db.select(db.commitments).getSingle();
    expect(row.encryptedData, contains('sarah@client.com'));
    expect(row.kind, 'iOwe');
    expect(row.status, 'open');
    expect(row.due, 'today');
  });

  test('is scoped by account and ordered newest message first', () async {
    await ds.upsertCommitments([
      commitment(id: 'iOwe:old', emailId: 'old',
          emailDate: now.subtract(const Duration(days: 2))),
      commitment(id: 'iOwe:new', emailId: 'new', emailDate: now),
      commitment(id: 'iOwe:other', emailId: 'other', account: 'other-acc'),
    ]);

    final acc = await ds.getCommitments('acc');
    expect(acc.map((c) => c.id), ['iOwe:new', 'iOwe:old']);
    expect((await ds.getCommitments('other-acc')).map((c) => c.id),
        ['iOwe:other']);
  });

  test('re-upserting keeps a user\'s done/dismissed verdict', () async {
    await ds.upsertCommitments([commitment()]);
    await ds.setStatus(
      accountId: 'acc',
      id: 'iOwe:e1',
      status: CommitmentStatus.done,
      now: now,
    );

    // A re-detection arrives as open again.
    await ds.upsertCommitments([commitment()]);

    final back = (await ds.getCommitments('acc')).single;
    expect(back.status, CommitmentStatus.done);
    expect(back.resolvedAt, now);
  });

  test('reopening clears the resolution time', () async {
    await ds.upsertCommitments([commitment()]);
    await ds.setStatus(
      accountId: 'acc',
      id: 'iOwe:e1',
      status: CommitmentStatus.dismissed,
      now: now,
    );
    await ds.setStatus(
      accountId: 'acc',
      id: 'iOwe:e1',
      status: CommitmentStatus.open,
      now: now.add(const Duration(minutes: 1)),
    );

    final back = (await ds.getCommitments('acc')).single;
    expect(back.status, CommitmentStatus.open);
    expect(back.resolvedAt, isNull);
  });

  test('scan markers are per account and idempotent', () async {
    await ds.markScanned(accountId: 'acc', emailIds: ['a', 'b'], now: now);
    await ds.markScanned(accountId: 'acc', emailIds: ['b', 'c'], now: now);
    await ds.markScanned(accountId: 'other', emailIds: ['z'], now: now);

    expect(await ds.getScannedEmailIds('acc'), {'a', 'b', 'c'});
    expect(await ds.getScannedEmailIds('other'), {'z'});
    expect(await ds.getScannedEmailIds('nobody'), isEmpty);
  });

  test('clearForAccount drops both the ledger and the markers', () async {
    await ds.upsertCommitments([commitment()]);
    await ds.markScanned(accountId: 'acc', emailIds: ['e1'], now: now);
    await ds.upsertCommitments([commitment(id: 'iOwe:o', account: 'other')]);

    await ds.clearForAccount('acc');

    expect(await ds.getCommitments('acc'), isEmpty);
    expect(await ds.getScannedEmailIds('acc'), isEmpty);
    expect(await ds.getCommitments('other'), hasLength(1));
  });

  test('a scheduled block round-trips and survives re-detection', () async {
    await ds.upsertCommitments([commitment()]);
    final start = DateTime(2026, 10, 5, 9);
    final end = DateTime(2026, 10, 5, 10);

    await ds.setSchedule(
      accountId: 'acc',
      id: 'iOwe:e1',
      eventId: 'ev-1',
      start: start,
      end: end,
    );
    var back = (await ds.getCommitments('acc')).single;
    expect(back.isScheduled, isTrue);
    expect(back.scheduledEventId, 'ev-1');
    expect(back.scheduledStart, start);
    expect(back.scheduledEnd, end);

    // A re-scan writes the row again without a schedule: the block stays.
    await ds.upsertCommitments([commitment()]);
    back = (await ds.getCommitments('acc')).single;
    expect(back.scheduledEventId, 'ev-1');
    expect(back.scheduledStart, start);
  });
}
