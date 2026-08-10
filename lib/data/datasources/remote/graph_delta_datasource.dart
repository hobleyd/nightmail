import '../../models/mail_delta_result.dart';

abstract interface class GraphDeltaDatasource {
  /// Fetches changes to messages in [folderId] since [deltaLink] was issued.
  ///
  /// Pass [deltaLink] as null for the initial sync, which pages through the
  /// folder under a client-side page budget and returns a delta link for future
  /// incremental calls — or, if the budget ran out first, the page cursor to
  /// resume from. There is deliberately no date filter: Graph bakes the
  /// originating query into the delta link, so a cutoff would be frozen there
  /// for its whole life. On subsequent calls, supply the stored link to receive
  /// only new, modified, or deleted messages since the last sync.
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  });
}
