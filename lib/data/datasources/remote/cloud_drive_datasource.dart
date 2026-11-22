import '../../../domain/entities/cloud_document.dart';
import '../../../domain/entities/cloud_file.dart';

/// The largest cloud file "Attach from Cloud" will download. Past it the file
/// belongs in the message as a link: providers refuse messages not much larger
/// (Gmail at 25 MB, Exchange Online at 35 MB by default once base64 inflates
/// the attachment by a third).
const int cloudAttachmentMaxBytes = 20 * 1024 * 1024;

/// One account's cloud drive: fetching a document a received message links to,
/// and browsing, downloading and sharing files for the compose window.
///
/// Follows the catalog datasource convention rather than the AI adapters':
/// these throw `ServerException`/`NetworkException`/`AuthException` and
/// `CloudDocumentNotPreviewableException`, and the repositories convert them —
/// `CloudDriveRepositoryImpl` has to inspect them anyway to decide whether to
/// try the next account.
abstract interface class CloudDriveDatasource {
  /// Downloads [link]'s document, asking the provider to convert it to PDF when
  /// that is the better preview.
  ///
  /// Throws `CloudDocumentNotPreviewableException` *before* downloading
  /// anything when the file is not something the reading pane can show.
  Future<CloudDocument> fetchDocument(CloudDocumentLink link);

  /// The items in [folder], or at the top of [collection] when [folder] is
  /// null. Folders first, then by name.
  Future<List<CloudFile>> listFiles({
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  });

  /// Files and folders whose name matches [query], across everything the
  /// provider's search reaches for this account.
  Future<List<CloudFile>> searchFiles(String query);

  /// [file]'s bytes, as an email attachment: the file itself, or — for a Google
  /// editor file, which has none — its export to the matching Office format.
  ///
  /// Throws `CloudDocumentNotPreviewableException` (the message says why) for
  /// a file too large to attach or one that cannot be exported.
  Future<CloudDocument> downloadFile(CloudFile file);

  /// Which of [recipients] [file]'s permissions do not cover. Recipients in
  /// [organizationDomains] are covered by an organization-wide link.
  ///
  /// Returns [CloudFileAccess.everyone] when the provider will not list the
  /// permissions to this account — there is then nothing to tell the sender.
  Future<CloudFileAccess> checkAccess(
    CloudFile file,
    List<String> recipients, {
    required Set<String> organizationDomains,
  });

  /// Grants each of [recipients] read access to [file], without the provider
  /// sending a notification of its own where it can be told not to — the
  /// message carrying the link is the notification.
  Future<CloudShareResult> shareFile(CloudFile file, List<String> recipients);
}
