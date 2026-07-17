/// Implemented by IMAP datasources that can sync the client-side Bayesian
/// spam filter (see [SpamFilterRepository]) via a dedicated `SPAMDB` folder
/// on the server, so multiple IMAP clients converge on the same trained
/// filter. Gmail/Graph accounts rely on server-side spam handling instead and
/// do not implement this.
///
/// Conflict resolution is last-write-wins, driven by a monotonically
/// increasing version number carried on the single message that lives in
/// `SPAMDB`.
abstract interface class SpamDbSyncDatasource {
  /// Cheap header-only check: returns the highest version number found among
  /// SPAMDB's messages, or null if the folder doesn't exist yet or is empty.
  ///
  /// If more than one message is present (a race from two clients pushing
  /// concurrently — append-then-delete-old isn't atomic), deletes every
  /// message except the highest-versioned one so the folder self-heals back
  /// to exactly one message.
  Future<int?> peekSpamDbVersion();

  /// Downloads and returns the base64 payload of the current (highest
  /// version) SPAMDB message. Returns null if the folder is missing/empty.
  ///
  /// Should be called after [peekSpamDbVersion] in the same sync pass, which
  /// self-heals any duplicate messages down to one before this reads it.
  Future<String?> downloadSpamDbPayload();

  /// Replaces SPAMDB's message with one carrying [version] and [payload],
  /// creating the folder first if it doesn't exist yet.
  Future<void> pushSpamDb({required int version, required String payload});
}
