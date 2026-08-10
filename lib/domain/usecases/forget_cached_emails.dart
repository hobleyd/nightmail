import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class ForgetCachedEmailsParams extends Equatable {
  const ForgetCachedEmailsParams({required this.emailIds});

  final List<String> emailIds;

  @override
  List<Object?> get props => [emailIds];
}

/// Drops rows from the local cache without touching the server.
///
/// Used for the messages a folder-scoped move or delete deliberately spares:
/// the copies of a thread that live in Sent or another folder. They were only
/// listed here as context for a thread that has now left the folder, so they
/// have to leave its cache too — otherwise the next repaint from cache brings
/// them back as orphan rows with no thread around them.
class ForgetCachedEmails implements UseCase<Unit, ForgetCachedEmailsParams> {
  const ForgetCachedEmails(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(ForgetCachedEmailsParams params) {
    return _repository.forgetCachedEmails(params.emailIds);
  }
}
