import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../repositories/email_repository.dart';

class DeleteServerDraft {
  const DeleteServerDraft(this._repository);

  final EmailRepository _repository;

  Future<Either<Failure, Unit>> call(String draftId) =>
      _repository.deleteServerDraft(draftId: draftId);
}
