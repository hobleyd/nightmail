import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class ReportJunk implements UseCase<Unit, ReportJunkParams> {
  const ReportJunk(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(ReportJunkParams params) {
    return _repository.reportJunk(params.id);
  }
}

class ReportJunkParams extends Equatable {
  const ReportJunkParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
