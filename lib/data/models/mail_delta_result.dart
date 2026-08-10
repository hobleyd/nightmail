import 'email_model.dart';

class MailDeltaResult {
  const MailDeltaResult({
    required this.upserted,
    required this.removedIds,
    required this.deltaLink,
    this.movedOutIds = const [],
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

  bool get hasChanges =>
      upserted.isNotEmpty || removedIds.isNotEmpty || movedOutIds.isNotEmpty;
}
