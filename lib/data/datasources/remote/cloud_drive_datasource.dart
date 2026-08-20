import '../../../domain/entities/cloud_document.dart';

/// Fetches one cloud document for one account.
///
/// Follows the catalog datasource convention rather than the AI adapters':
/// these throw `ServerException`/`NetworkException`/`AuthException` and
/// `CloudDocumentNotPreviewableException`, and `CloudDriveRepositoryImpl`
/// converts them — it has to inspect them anyway to decide whether to try the
/// next account.
abstract interface class CloudDriveDatasource {
  /// Downloads [link]'s document, asking the provider to convert it to PDF when
  /// that is the better preview.
  ///
  /// Throws `CloudDocumentNotPreviewableException` *before* downloading
  /// anything when the file is not something the reading pane can show.
  Future<CloudDocument> fetchDocument(CloudDocumentLink link);
}
