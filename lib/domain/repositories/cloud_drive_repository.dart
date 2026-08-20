import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/cloud_document.dart';

/// Fetches the document a cloud link in a message body points at.
///
/// The link decides the provider; the *account* is chosen by the implementation
/// from whoever is signed in to that service, because a OneDrive link arrives
/// in Gmail and a Drive link in Exchange as a matter of course.
abstract interface class CloudDriveRepository {
  /// Downloads [link]'s document, converted to PDF by the provider where that
  /// is both possible and better than the raw file (Office formats, Google
  /// editor files).
  Future<Either<Failure, CloudDocument>> fetchDocument(CloudDocumentLink link);
}
