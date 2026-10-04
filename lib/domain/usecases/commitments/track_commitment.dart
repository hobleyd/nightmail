import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/commitment.dart';
import '../../entities/email.dart';
import '../../repositories/commitment_repository.dart';
import 'commitment_ledger_changes.dart';
import 'detect_commitments.dart';

/// Puts a message on the commitments ledger because the user said so.
///
/// The model misses things — a weak local checkpoint misses most things (see
/// `docs/claude/commitments.md`) — and a request that slipped through should
/// not have to wait for a better model. The user picks the kind and a coarse
/// due reading in the reading pane; everything else is read off the message
/// the same way `DetectCommitments` would: the counterpart, the subject, the
/// excerpt, the date. The row is keyed like a detected one (`<kind>:<emailId>`)
/// so a later scan can never duplicate it, and:
///
/// * it carries `confidence` 1 — the user's own verdict;
/// * a row the user had closed is **reopened** — tracking is an explicit ask,
///   unlike a re-detection, which must respect a Done;
/// * the message is **marked scanned**, so the model is not asked about a
///   message the user has already decided on;
/// * no effort estimate is set — the next scan's estimate pass sizes it like
///   any other unsized row;
/// * [CommitmentLedgerChanges] is told, so an open Commitments pane shows the
///   row at once.
class TrackCommitment {
  const TrackCommitment({
    required this.commitmentRepository,
    required this.ledgerChanges,
  });

  final CommitmentRepository commitmentRepository;
  final CommitmentLedgerChanges ledgerChanges;

  Future<Either<Failure, Commitment>> call(TrackCommitmentParams params) async {
    final email = params.email;
    final outgoing = DetectCommitments.isFromSelf(email, params.selfAddresses);
    final commitment = Commitment(
      id: Commitment.idFor(params.kind, email.id),
      accountId: params.accountId,
      emailId: email.id,
      conversationId: email.conversationId,
      kind: params.kind,
      status: CommitmentStatus.open,
      counterpart: DetectCommitments.counterpartFor(
        email,
        params.selfAddresses,
        outgoing: outgoing,
      ),
      subject: email.subject,
      snippet: DetectCommitments.snippetFor(email),
      due: params.due,
      urgency: urgencyFor(params.due),
      confidence: 1,
      emailDate: email.sentDateTime ?? email.receivedDateTime,
      detectedAt: params.now,
    );

    final saved = await commitmentRepository.saveCommitments([commitment]);
    if (saved.isLeft()) return Left(saved.getLeft().toNullable()!);

    // The upsert keeps an existing row's status; the user asking again
    // overrides a Done or Dismiss they gave earlier.
    final reopened = await commitmentRepository.setStatus(
      accountId: params.accountId,
      id: commitment.id,
      status: CommitmentStatus.open,
      now: params.now,
    );
    if (reopened.isLeft()) return Left(reopened.getLeft().toNullable()!);

    final marked = await commitmentRepository.markScanned(
      accountId: params.accountId,
      emailIds: [email.id],
      now: params.now,
    );
    if (marked.isLeft()) return Left(marked.getLeft().toNullable()!);

    ledgerChanges.notify(params.accountId);
    return Right(commitment);
  }

  /// The urgency a hand-tracked row gets from its due reading, on the same
  /// three-level scale the model uses: a same-day item is blocking, a
  /// this-week item needs attention soon, the rest have no time pressure.
  static int urgencyFor(CommitmentDue due) => switch (due) {
        CommitmentDue.today => 2,
        CommitmentDue.thisWeek => 1,
        CommitmentDue.later || CommitmentDue.none => 0,
      };
}

class TrackCommitmentParams extends Equatable {
  const TrackCommitmentParams({
    required this.accountId,
    required this.selfAddresses,
    required this.email,
    required this.kind,
    required this.due,
    required this.now,
  });

  final String accountId;

  /// The account holder's addresses, lower-cased.
  final Set<String> selfAddresses;

  final Email email;
  final CommitmentKind kind;
  final CommitmentDue due;
  final DateTime now;

  @override
  List<Object?> get props => [accountId, selfAddresses, email, kind, due, now];
}
