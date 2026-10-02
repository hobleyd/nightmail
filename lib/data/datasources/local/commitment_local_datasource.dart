import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/email_address.dart';
import '../../../infrastructure/cache/cache_encryption_service.dart';
import '../../database/app_database.dart';

/// Durable storage for the commitment ledger (`commitments`) and the scan
/// markers (`commitment_scans`).
///
/// The columns a query needs — kind, status, due, dates, the message and
/// thread ids — are plaintext, like `cached_emails`' own index columns. What
/// a row says about a *person* (who, the subject, the excerpt of what they
/// wrote) travels in one encrypted JSON blob, the same way the mail cache
/// keeps message content.
abstract interface class CommitmentLocalDatasource {
  Future<List<Commitment>> getCommitments(String accountId);

  /// Inserts new rows and refreshes existing ones **without** touching an
  /// existing row's status or resolution time, so a re-detection cannot
  /// reopen what the user closed.
  Future<void> upsertCommitments(List<Commitment> commitments);

  Future<void> setStatus({
    required String accountId,
    required String id,
    required CommitmentStatus status,
    required DateTime now,
  });

  Future<Set<String>> getScannedEmailIds(String accountId);

  Future<void> markScanned({
    required String accountId,
    required Iterable<String> emailIds,
    required DateTime now,
  });

  Future<void> clearForAccount(String accountId);
}

class CommitmentLocalDatasourceImpl implements CommitmentLocalDatasource {
  CommitmentLocalDatasourceImpl({
    required AppDatabase database,
    required CacheEncryptionService encryption,
  })  : _db = database,
        _encryption = encryption; // ignore: prefer_initializing_formals

  final AppDatabase _db;
  final CacheEncryptionService _encryption;

  @override
  Future<List<Commitment>> getCommitments(String accountId) async {
    final rows = await (_db.select(_db.commitments)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.desc(t.emailDateMs)]))
        .get();
    final out = <Commitment>[];
    for (final row in rows) {
      out.add(await _fromRow(row));
    }
    return out;
  }

  @override
  Future<void> upsertCommitments(List<Commitment> commitments) async {
    if (commitments.isEmpty) return;
    await _db.transaction(() async {
      for (final c in commitments) {
        final existing = await (_db.select(_db.commitments)
              ..where((t) => t.accountId.equals(c.accountId) & t.id.equals(c.id)))
            .getSingleOrNull();
        // Preserve the user's verdict on a row that is already there.
        final status = existing?.status ?? c.status.name;
        final resolvedAtMs =
            existing?.resolvedAtMs ?? c.resolvedAt?.millisecondsSinceEpoch;
        await _db.into(_db.commitments).insertOnConflictUpdate(
              CommitmentsCompanion(
                id: Value(c.id),
                accountId: Value(c.accountId),
                emailId: Value(c.emailId),
                conversationId: Value(c.conversationId),
                kind: Value(c.kind.name),
                status: Value(status),
                due: Value(c.due.name),
                urgency: Value(c.urgency),
                confidence: Value(c.confidence),
                emailDateMs: Value(c.emailDate.millisecondsSinceEpoch),
                detectedAtMs: Value(c.detectedAt.millisecondsSinceEpoch),
                resolvedAtMs: Value(resolvedAtMs),
                encryptedData: Value(await _encryption.encrypt(jsonEncode({
                  'subject': c.subject,
                  'snippet': c.snippet,
                  'counterpartAddress': c.counterpart.address,
                  'counterpartName': c.counterpart.name,
                }))),
              ),
            );
      }
    });
  }

  @override
  Future<void> setStatus({
    required String accountId,
    required String id,
    required CommitmentStatus status,
    required DateTime now,
  }) async {
    await (_db.update(_db.commitments)
          ..where((t) => t.accountId.equals(accountId) & t.id.equals(id)))
        .write(
      CommitmentsCompanion(
        status: Value(status.name),
        resolvedAtMs: Value(
          status == CommitmentStatus.open ? null : now.millisecondsSinceEpoch,
        ),
      ),
    );
  }

  @override
  Future<Set<String>> getScannedEmailIds(String accountId) async {
    final rows = await (_db.selectOnly(_db.commitmentScans)
          ..addColumns([_db.commitmentScans.emailId])
          ..where(_db.commitmentScans.accountId.equals(accountId)))
        .get();
    return {
      for (final r in rows) r.read(_db.commitmentScans.emailId)!,
    };
  }

  @override
  Future<void> markScanned({
    required String accountId,
    required Iterable<String> emailIds,
    required DateTime now,
  }) async {
    final ids = emailIds.toList();
    if (ids.isEmpty) return;
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.commitmentScans, [
        for (final id in ids)
          CommitmentScansCompanion(
            accountId: Value(accountId),
            emailId: Value(id),
            scannedAtMs: Value(now.millisecondsSinceEpoch),
          ),
      ]);
    });
  }

  @override
  Future<void> clearForAccount(String accountId) async {
    await _db.transaction(() async {
      await (_db.delete(_db.commitments)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
      await (_db.delete(_db.commitmentScans)
            ..where((t) => t.accountId.equals(accountId)))
          .go();
    });
  }

  Future<Commitment> _fromRow(CommitmentRow row) async {
    final data = jsonDecode(await _encryption.decrypt(row.encryptedData))
        as Map<String, dynamic>;
    return Commitment(
      id: row.id,
      accountId: row.accountId,
      emailId: row.emailId,
      conversationId: row.conversationId,
      kind: CommitmentKind.values.firstWhere(
        (k) => k.name == row.kind,
        orElse: () => CommitmentKind.needsAction,
      ),
      status: CommitmentStatus.values.firstWhere(
        (s) => s.name == row.status,
        orElse: () => CommitmentStatus.open,
      ),
      counterpart: EmailAddress(
        address: (data['counterpartAddress'] as String?) ?? '',
        name: data['counterpartName'] as String?,
      ),
      subject: (data['subject'] as String?) ?? '',
      snippet: (data['snippet'] as String?) ?? '',
      due: CommitmentDue.values.firstWhere(
        (d) => d.name == row.due,
        orElse: () => CommitmentDue.none,
      ),
      urgency: row.urgency,
      confidence: row.confidence,
      emailDate: DateTime.fromMillisecondsSinceEpoch(row.emailDateMs),
      detectedAt: DateTime.fromMillisecondsSinceEpoch(row.detectedAtMs),
      resolvedAt: row.resolvedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.resolvedAtMs!),
    );
  }
}
