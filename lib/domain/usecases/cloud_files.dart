import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/cloud_document.dart';
import '../entities/cloud_file.dart';
import '../repositories/cloud_file_repository.dart';

/// The compose window's cloud picker operations — see [CloudFileRepository].
/// Kept in one file: each is a single forwarding call, and they are only ever
/// used together.

class ListCloudFiles {
  const ListCloudFiles(this._repository);
  final CloudFileRepository _repository;

  Future<Either<Failure, List<CloudFile>>> call(
    String accountId, {
    CloudFile? folder,
    CloudFileCollection collection = CloudFileCollection.myFiles,
  }) =>
      _repository.listFiles(accountId, folder: folder, collection: collection);
}

class SearchCloudFiles {
  const SearchCloudFiles(this._repository);
  final CloudFileRepository _repository;

  Future<Either<Failure, List<CloudFile>>> call(
          String accountId, String query) =>
      _repository.searchFiles(accountId, query);
}

class DownloadCloudFile {
  const DownloadCloudFile(this._repository);
  final CloudFileRepository _repository;

  Future<Either<Failure, CloudDocument>> call(CloudFile file) =>
      _repository.downloadFile(file);
}

class CheckCloudFileAccess {
  const CheckCloudFileAccess(this._repository);
  final CloudFileRepository _repository;

  Future<Either<Failure, CloudFileAccess>> call(
          CloudFile file, List<String> recipients) =>
      _repository.checkAccess(file, recipients);
}

class ShareCloudFile {
  const ShareCloudFile(this._repository);
  final CloudFileRepository _repository;

  Future<Either<Failure, CloudShareResult>> call(
          CloudFile file, List<String> recipients) =>
      _repository.shareFile(file, recipients);
}
