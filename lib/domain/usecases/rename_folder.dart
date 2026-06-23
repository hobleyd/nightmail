import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class RenameFolder implements UseCase<Unit, RenameFolderParams> {
  const RenameFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(RenameFolderParams params) {
    return _repository.renameFolder(
      folderId: params.folderId,
      newDisplayName: params.newDisplayName,
    );
  }
}

class RenameFolderParams extends Equatable {
  const RenameFolderParams({
    required this.folderId,
    required this.newDisplayName,
  });

  final String folderId;
  final String newDisplayName;

  @override
  List<Object?> get props => [folderId, newDisplayName];
}
