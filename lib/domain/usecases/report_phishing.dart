import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/email_repository.dart';

class ReportPhishing implements UseCase<Unit, ReportPhishingParams> {
  const ReportPhishing(this._repository);

  final EmailRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(ReportPhishingParams params) {
    return _repository.reportPhishing(params.id);
  }
}

class ReportPhishingParams extends Equatable {
  const ReportPhishingParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
