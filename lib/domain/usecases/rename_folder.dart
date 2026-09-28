import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

/// Renames a folder and returns its id afterwards — see
/// [EmailRepository.renameFolder] for why that is not always the id that went
/// in.
class RenameFolder implements UseCase<String, RenameFolderParams> {
  const RenameFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, String>> call(RenameFolderParams params) {
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
