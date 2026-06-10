import '../../models/mail_delta_result.dart';

abstract interface class GraphDeltaDatasource {
  /// Fetches changes to messages in [folderId] since [deltaLink] was issued.
  ///
  /// Pass [deltaLink] as null for the initial sync, which pages through recent
  /// messages (last 30 days) and returns a delta link for future incremental
  /// calls. On subsequent calls, supply the stored delta link to receive only
  /// new, modified, or deleted messages since the last sync.
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  });
}
