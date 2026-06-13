import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email_folder.dart';
import '../repositories/email_repository.dart';

class GetCachedFolders implements UseCase<List<EmailFolder>, String> {
  const GetCachedFolders(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<EmailFolder>>> call(String accountId) {
    return _repository.getCachedFolders(accountId);
  }
}
