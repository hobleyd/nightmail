import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/email.dart';
import '../repositories/email_repository.dart';

class GetEmail implements UseCase<Email, GetEmailParams> {
  const GetEmail(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Email>> call(GetEmailParams params) {
    return _repository.getEmail(params.id);
  }
}

class GetEmailParams extends Equatable {
  const GetEmailParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
