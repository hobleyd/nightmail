import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/commitment.dart';

/// The commitment ledger: what the System One model has lifted out of an
/// account's mail, and which messages it has already been asked about.
///
/// Scan markers are kept separately from commitments because most messages
/// produce none — a message the model judged uninteresting still must not be
/// sent to it again on the next refresh.
abstract interface class CommitmentRepository {
  /// Every commitment recorded for [accountId], all statuses, newest message
  /// first. Callers filter by [Commitment.status].
  Future<Either<Failure, List<Commitment>>> getCommitments({
    required String accountId,
  });

  /// Records newly detected commitments. A row that already exists keeps its
  /// status — a user's *done* or *dismissed* must survive a re-detection.
  Future<Either<Failure, Unit>> saveCommitments(List<Commitment> commitments);

  /// Changes one commitment's status; [resolvedAt] is stamped for *done* and
  /// *dismissed* and cleared when it is reopened.
  Future<Either<Failure, Unit>> setStatus({
    required String accountId,
    required String id,
    required CommitmentStatus status,
    required DateTime now,
  });

  /// Records the calendar event that blocks time for a commitment (or moves
  /// the block, when the same event is rescheduled).
  Future<Either<Failure, Unit>> setSchedule({
    required String accountId,
    required String id,
    required String eventId,
    required DateTime start,
    required DateTime end,
  });

  /// Records the model's effort estimate for a commitment, in minutes —
  /// filled in later for rows written before the estimate existed.
  Future<Either<Failure, Unit>> setEstimate({
    required String accountId,
    required String id,
    required int minutes,
  });

  /// Ids of the messages already shown to the model for [accountId].
  Future<Either<Failure, Set<String>>> getScannedEmailIds({
    required String accountId,
  });

  /// Marks messages as scanned, whether or not they produced a commitment.
  Future<Either<Failure, Unit>> markScanned({
    required String accountId,
    required Iterable<String> emailIds,
    required DateTime now,
  });
}
