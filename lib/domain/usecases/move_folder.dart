import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class MoveFolder implements UseCase<Unit, MoveFolderParams> {
  const MoveFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(MoveFolderParams params) {
    return _repository.moveFolder(
      folderId: params.folderId,
      newParentFolderId: params.newParentFolderId,
    );
  }
}

class MoveFolderParams extends Equatable {
  const MoveFolderParams({
    required this.folderId,
    required this.newParentFolderId,
  });

  final String folderId;
  final String newParentFolderId;

  @override
  List<Object?> get props => [folderId, newParentFolderId];
}
