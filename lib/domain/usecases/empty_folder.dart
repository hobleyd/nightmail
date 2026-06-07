import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class EmptyFolder implements UseCase<Unit, EmptyFolderParams> {
  const EmptyFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(EmptyFolderParams params) {
    return _repository.emptyFolder(
      params.folderId,
      permanentDelete: params.permanentDelete,
    );
  }
}

class EmptyFolderParams extends Equatable {
  const EmptyFolderParams({
    required this.folderId,
    this.permanentDelete = false,
  });

  final String folderId;
  final bool permanentDelete;

  @override
  List<Object?> get props => [folderId, permanentDelete];
}
