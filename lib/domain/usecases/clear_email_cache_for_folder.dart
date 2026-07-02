import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class ClearEmailCacheForFolder
    implements UseCase<Unit, ClearEmailCacheForFolderParams> {
  const ClearEmailCacheForFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(ClearEmailCacheForFolderParams params) {
    return _repository.clearCacheForFolder(
      accountId: params.accountId,
      folderId: params.folderId,
    );
  }
}

class ClearEmailCacheForFolderParams extends Equatable {
  const ClearEmailCacheForFolderParams({
    required this.accountId,
    required this.folderId,
  });

  final String accountId;
  final String folderId;

  @override
  List<Object?> get props => [accountId, folderId];
}
