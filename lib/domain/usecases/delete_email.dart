import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class DeleteEmail implements UseCase<Unit, DeleteEmailParams> {
  const DeleteEmail(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(DeleteEmailParams params) {
    return _repository.deleteEmail(params.id);
  }
}

class DeleteEmailParams extends Equatable {
  const DeleteEmailParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
