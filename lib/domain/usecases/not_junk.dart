import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class NotJunk implements UseCase<Unit, NotJunkParams> {
  const NotJunk(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(NotJunkParams params) {
    return _repository.notJunk(params.id);
  }
}

class NotJunkParams extends Equatable {
  const NotJunkParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
