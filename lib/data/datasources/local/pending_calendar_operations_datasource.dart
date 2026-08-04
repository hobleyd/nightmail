/// The calendar mutations that can be queued for replay against the server.
///
/// Split by what the op targets, because the two halves are located
/// differently and neither locator is available on the other side:
///
/// * **Event ops** — [cancelEvent] … [updateEvent]. Target an event id, which
///   the calendar pane already has in hand.
/// * **Invitation ops** — [respondToInvite] … [cancelMeetingFromEmail]. Target
///   the *email id* of the invitation, because that is all the mail reading
///   pane knows. The provider resolves it to an event itself (Graph via
///   `/message/{id}/accept`, the others via the `UID` in the attached ICS).
///
/// Some calendar mutations are deliberately **not** here and stay
/// network-first:
///
/// * `proposeNewTimeFromEmail` and `acceptProposedTimeFromEmail` send mail to
///   other people (a `METHOD:COUNTER` reply, a re-issued invitation). An op
///   that emails somebody cannot be retried blindly — a partial failure would
///   send the same proposal twice — so these wait for the server and patch the
///   cache once it answers.
/// * `createCalendarEvent` needs the id the provider assigns before it can be
///   cached at all.
/// * `cancelMeetingFromEmail` carries no ICS, so there is no `UID` to find the
///   cached copy by; queueing it would delay the error report and buy no
///   optimistic update.
enum PendingCalendarOperationType {
  cancelEvent,
  cancelSeries,
  declineEvent,
  proposeNewTime,
  updateEvent,
  respondToInvite,
  removeMeetingFromCalendar,
}

class PendingCalendarOperationRecord {
  const PendingCalendarOperationRecord({
    required this.id,
    required this.accountId,
    required this.targetId,
    required this.opType,
    required this.payload,
    required this.createdAtMs,
    required this.retryCount,
    required this.lastError,
  });

  final int id;
  final String accountId;

  /// An event id for the event ops, an email id for the invitation ops — see
  /// [PendingCalendarOperationType].
  final String targetId;

  final PendingCalendarOperationType opType;

  /// Op-specific parameters as a JSON string (e.g. the whole
  /// `UpdateCalendarEventParams` for [PendingCalendarOperationType.updateEvent],
  /// `{"response": "accept"}` for [PendingCalendarOperationType.respondToInvite]).
  /// Empty object for ops that need no extra data.
  final String payload;

  final int createdAtMs;
  final int retryCount;
  final String? lastError;
}

/// Durable queue of calendar mutations awaiting a server round-trip. Lets an
/// accept/decline/reschedule land in the local calendar cache and appear on
/// screen immediately — even offline — with the provider call replayed later by
/// `CalendarOutboxDrainService`.
abstract interface class PendingCalendarOperationsDatasource {
  /// Adds a new queued operation and returns its id.
  Future<int> enqueueCalendarOperation({
    required String accountId,
    required String targetId,
    required PendingCalendarOperationType opType,
    required String payload,
  });

  /// All queued calendar operations for [accountId], oldest first. Draining
  /// must keep that order for ops sharing a [targetId]: an accept followed by
  /// a reschedule of the same meeting only makes sense in the order the user
  /// performed them.
  Future<List<PendingCalendarOperationRecord>> getPendingCalendarOperations(
      String accountId);

  /// Removes an operation once it has been successfully replayed.
  Future<void> removeCalendarOperation(int id);

  /// Records a failed replay attempt so the drain engine can back off and
  /// eventually give up rather than retry forever.
  Future<void> recordCalendarOperationFailure({
    required int id,
    required String error,
  });

  /// Drops every queued operation for [accountId] — called when the account is
  /// removed, so nothing is replayed against a mailbox that is no longer set up.
  Future<void> clearCalendarOperationsForAccount(String accountId);
}
