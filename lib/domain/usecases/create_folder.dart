import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class CreateFolder implements UseCase<Unit, CreateFolderParams> {
  const CreateFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(CreateFolderParams params) {
    return _repository.createFolder(
      parentFolderId: params.parentFolderId,
      displayName: params.displayName,
    );
  }
}

class CreateFolderParams extends Equatable {
  const CreateFolderParams({
    required this.parentFolderId,
    required this.displayName,
  });

  final String parentFolderId;
  final String displayName;

  @override
  List<Object?> get props => [parentFolderId, displayName];
}
