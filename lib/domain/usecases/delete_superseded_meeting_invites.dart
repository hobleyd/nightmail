import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../../core/utils/meeting_conflicts.dart';
import '../entities/email.dart';
import '../entities/meeting_invite.dart';
import '../repositories/email_repository.dart';

/// Deletes the *older* invitations to the meeting the user has just answered.
///
/// A meeting that is rescheduled or otherwise updated arrives as a fresh
/// invitation each time, and answering the latest one leaves every earlier one
/// sitting in the folder as if it still wanted an answer. Those are superseded
/// by the reply just given, so this removes them the way the reading pane
/// removes the invitation that was answered.
///
/// What counts as "the same meeting" depends on what the provider hands over:
///
/// - **ICS `UID`** where both messages carry one (Gmail, IMAP). This is the
///   definitive test, and it has to be: Gmail files an "Updated invitation"
///   in a thread of its own, so the conversation says nothing there.
/// - **The conversation** otherwise (Microsoft Graph, whose event messages
///   carry no ICS). Exchange keeps a meeting request and every update to it
///   in one conversation, and nothing else of type invitation lands in it.
///
/// A list row does not carry its invite — that lives with the body — so each
/// candidate is read through [EmailRepository.getEmail], which is cache-first
/// and costs a network round trip only for a message never opened or
/// prefetched. Candidates are therefore narrowed first to what could plausibly
/// be an earlier copy of the same invitation: older, in the same folder, and
/// either in the same conversation or from the same sender (an update comes
/// from the organizer, as the original did). The remainder is capped at
/// [maxCandidates] so a prolific organizer cannot turn one Accept into a
/// folder-wide fetch.
///
/// Only messages of [MeetingEmailType.invitation] are ever removed. A
/// cancellation, a reply or a counter-proposal in the same thread is a
/// different message with its own banner, and is left alone.
///
/// Returns the messages deleted, so the caller can take them off screen and
/// adjust folder counts. A candidate that cannot be read is skipped, not
/// reported: this runs as a tidy-up after a successful RSVP and must never
/// make that RSVP look like it failed.
class DeleteSupersededMeetingInvites
    implements UseCase<List<Email>, DeleteSupersededMeetingInvitesParams> {
  const DeleteSupersededMeetingInvites(this._repository);

  final EmailRepository _repository;

  /// How many plausible candidates are read before giving up on the rest.
  static const int maxCandidates = 20;

  @override
  Future<Either<Failure, List<Email>>> call(
    DeleteSupersededMeetingInvitesParams params,
  ) async {
    final answered = params.answered;
    final folderId = answered.parentFolderId;
    if (folderId == null || answered.meetingInvite == null) {
      return const Right([]);
    }

    final cached = await _repository.getCachedEmails(
      accountId: params.accountId,
      folderId: folderId,
    );
    final rows = cached.getOrElse((_) => const []);
    final failure = cached.getLeft().toNullable();
    if (failure != null) return Left(failure);

    final candidates =
        rows
            .where((row) => isPlausibleEarlierInvite(row, answered, folderId))
            .toList()
          ..sort((a, b) => b.receivedDateTime.compareTo(a.receivedDateTime));

    final deleted = <Email>[];
    for (final row in candidates.take(maxCandidates)) {
      final read = await _repository.getEmail(row.id);
      final email = read.getOrElse((_) => row);
      if (read.isLeft()) continue;
      if (!isSupersededInviteOf(email, answered)) continue;

      final result = await _repository.deleteEmail(
        email.id,
        accountId: params.accountId,
      );
      if (result.isRight()) deleted.add(email);
    }
    return Right(deleted);
  }
}

/// Whether [row] — a list row, invite unknown — is worth reading to find out
/// whether it is an earlier invitation to the meeting [answered] answers.
///
/// Older than [answered], physically in [folderId] (a folder listing carries
/// other folders' copies of a thread, and a folder-scoped tidy-up must leave
/// those be), and either in [answered]'s conversation or from its sender.
bool isPlausibleEarlierInvite(Email row, Email answered, String folderId) {
  if (row.id == answered.id) return false;
  if (!row.receivedDateTime.isBefore(answered.receivedDateTime)) return false;
  if (!row.isInFolder(folderId)) return false;
  return _sameConversation(row, answered) || _sameSender(row, answered);
}

/// Whether [candidate], read in full, is an invitation to the same meeting as
/// [answered] and so superseded by the answer just given.
///
/// UIDs decide it when both messages have one — normalised through
/// [isSameMeetingUid], so Google's per-instance suffix does not split a
/// series from its own update. Without a UID on both sides the two have to
/// share a conversation. Neither test lets an unknown UID match everything.
bool isSupersededInviteOf(Email candidate, Email answered) {
  final invite = candidate.meetingInvite;
  if (invite == null || invite.type != MeetingEmailType.invitation) {
    return false;
  }
  final answeredUid = answered.meetingInvite?.uid;
  if (invite.uid != null && answeredUid != null) {
    return isSameMeetingUid(invite.uid, answeredUid);
  }
  return _sameConversation(candidate, answered);
}

bool _sameConversation(Email a, Email b) {
  final id = a.conversationId;
  return id != null && id.isNotEmpty && id == b.conversationId;
}

bool _sameSender(Email a, Email b) {
  final address = a.from.address.trim().toLowerCase();
  return address.isNotEmpty && address == b.from.address.trim().toLowerCase();
}

class DeleteSupersededMeetingInvitesParams extends Equatable {
  const DeleteSupersededMeetingInvitesParams({
    required this.answered,
    required this.accountId,
  });

  /// The invitation the user just answered, as the reading pane holds it —
  /// with its invite, so the meeting's UID is known where the provider gives
  /// one.
  final Email answered;

  /// The account the invitation belongs to; the cache is read under it.
  final String accountId;

  @override
  List<Object?> get props => [answered, accountId];
}
