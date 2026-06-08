import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class MoveEmail implements UseCase<Unit, MoveEmailParams> {
  const MoveEmail(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(MoveEmailParams params) {
    return _repository.moveEmail(params.id, params.destinationFolderId);
  }
}

class MoveEmailParams extends Equatable {
  const MoveEmailParams({
    required this.id,
    required this.destinationFolderId,
  });

  final String id;
  final String destinationFolderId;

  @override
  List<Object?> get props => [id, destinationFolderId];
}
