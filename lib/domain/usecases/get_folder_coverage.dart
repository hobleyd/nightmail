import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/folder_listing.dart';
import '../repositories/email_repository.dart';

class GetFolderCoverageParams extends Equatable {
  const GetFolderCoverageParams({
    required this.accountId,
    required this.folderId,
  });

  final String accountId;
  final String folderId;

  @override
  List<Object?> get props => [accountId, folderId];
}

/// How much of a folder the cache vouches for — see [FolderCoverage].
class GetFolderCoverage
    implements UseCase<FolderCoverage, GetFolderCoverageParams> {
  const GetFolderCoverage(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, FolderCoverage>> call(GetFolderCoverageParams params) =>
      _repository.getFolderCoverage(
        accountId: params.accountId,
        folderId: params.folderId,
      );
}
