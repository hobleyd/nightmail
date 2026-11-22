import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/cloud_document.dart';
import '../entities/cloud_file.dart';

/// Browses, downloads and shares files in the signed-in accounts' cloud
/// drives, for the compose window's "Attach from Cloud" and "Link from Cloud".
///
/// Every call names its account — through [CloudFile.accountId] or explicitly
/// — because the sender chose which drive to browse; unlike
/// [CloudDriveRepository] nothing here picks an account for them.
abstract interface class CloudFileRepository {
  Future<Either<Failure, List<CloudFile>>> listFiles(
    String accountId, {
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  });

  Future<Either<Failure, List<CloudFile>>> searchFiles(
      String accountId, String query);

  /// The file's bytes as an attachment. A Google editor file comes back as its
  /// Office export, named with the matching extension.
  Future<Either<Failure, CloudDocument>> downloadFile(CloudFile file);

  /// Which of [recipients] cannot open [file] through any permission it has.
  /// The sender's own addresses are never reported.
  Future<Either<Failure, CloudFileAccess>> checkAccess(
      CloudFile file, List<String> recipients);

  /// Grants [recipients] read access to [file].
  Future<Either<Failure, CloudShareResult>> shareFile(
      CloudFile file, List<String> recipients);
}
