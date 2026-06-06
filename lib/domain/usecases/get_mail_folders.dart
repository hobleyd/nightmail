import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email_folder.dart';
import '../repositories/email_repository.dart';

class GetMailFolders implements UseCase<List<EmailFolder>, NoParams> {
  const GetMailFolders(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, List<EmailFolder>>> call(NoParams params) {
    return _repository.getMailFolders();
  }
}
