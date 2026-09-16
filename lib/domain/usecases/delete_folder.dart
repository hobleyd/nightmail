import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

/// Deletes a folder and everything inside it. The parameter is the folder id.
class DeleteFolder implements UseCase<Unit, String> {
  const DeleteFolder(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(String folderId) {
    return _repository.deleteFolder(folderId: folderId);
  }
}
