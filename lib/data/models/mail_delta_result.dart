import 'email_model.dart';

/// A delta item that named only the properties that changed, not a whole
/// message.
///
/// Graph answers a read-state or follow-up-flag change with the message's id
/// and the changed property alone — none of the rest of the projection. Parsed
/// as if it were a whole message it yields a row with no sender, no subject and
/// an epoch date, and caching that *replaces* the real row: the message drops
/// to the bottom of the list, blank, until a full fetch repairs it. So these
/// are kept apart from [MailDeltaResult.upserted] and applied to the cached row
/// field by field.
class MailDeltaFieldUpdate {
  const MailDeltaFieldUpdate({
    required this.id,
    this.isRead,
    this.isFlagged,
  });

  final String id;

  /// Null means the item did not carry the property — leave the cached value
  /// alone. Reading an absent property as `false` is the same mistake in
  /// smaller form: it would mark a read message unread, or clear a live flag.
  final bool? isRead;
  final bool? isFlagged;

  /// True when the item changed nothing this app stores, so there is nothing
  /// to apply.
  bool get isEmpty => isRead == null && isFlagged == null;
}

class MailDeltaResult {
  const MailDeltaResult({
    required this.upserted,
    required this.removedIds,
    required this.deltaLink,
    this.movedOutIds = const [],
    this.fieldUpdates = const [],
  });

  final List<EmailModel> upserted;

  /// Messages gone from the mailbox entirely. Their cached inline images go too.
  final List<String> removedIds;

  final String deltaLink;

  /// Messages that have left the synced folder but still exist elsewhere in the
  /// mailbox — a move. Separate from [removedIds] because the cached row should
  /// go without taking the message's inline images with it: the destination
  /// folder would only have to download every one of them again.
  final List<String> movedOutIds;

  /// Changes that name only the properties that moved — see
  /// [MailDeltaFieldUpdate].
  final List<MailDeltaFieldUpdate> fieldUpdates;

  bool get hasChanges =>
      upserted.isNotEmpty ||
      removedIds.isNotEmpty ||
      movedOutIds.isNotEmpty ||
      fieldUpdates.isNotEmpty;
}
