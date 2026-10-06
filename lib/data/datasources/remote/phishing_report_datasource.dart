/// A provider that can be *told* a message is phishing, over and above having
/// the message filed as junk.
///
/// Only Graph implements it, through the threat submission API — the same
/// channel Outlook's own Report button feeds, so the report lands in the
/// tenant's Submissions portal and in Microsoft's filters. Gmail has no API
/// for the "Report phishing" its web client offers (the Gmail API's only lever
/// is the `SPAM` label) and IMAP has nothing at all, so for them reporting
/// phishing is `EmailRemoteDatasource.reportJunk` under its honest name, and
/// `EmailRepositoryImpl.reportPhishing` tests for this interface with `is` —
/// the `ConversationFolderDatasource` precedent — rather than making the other
/// two providers stub a method they can never honour.
abstract interface class PhishingReportDatasource {
  /// Submits the message with id [id] to the provider as phishing.
  ///
  /// Names the message by the id it has *now*: the caller must submit before
  /// it files the message as junk, because that move mints a new id on Graph
  /// and the report would then point at nothing. Throws the usual
  /// `ServerException`/`AuthException`/`NetworkException` on failure; a 403 is
  /// what a tenant answers when `ThreatSubmission.ReadWrite` was never
  /// consented to, which `AccountManager.hasThreatSubmissionAccess` is meant
  /// to have ruled out beforehand.
  Future<void> submitPhishingReport(String id);
}
