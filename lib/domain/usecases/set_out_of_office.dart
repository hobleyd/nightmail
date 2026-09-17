import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/out_of_office_settings.dart';
import '../repositories/out_of_office_repository.dart';

class SetOutOfOffice implements UseCase<Unit, SetOutOfOfficeParams> {
  const SetOutOfOffice(this._repository);

  final OutOfOfficeRepository _repository;

  @override
  Future<Either<Failure, Unit>> call(SetOutOfOfficeParams params) =>
      _repository.setOutOfOffice(params.accountId, params.settings);
}

class SetOutOfOfficeParams extends Equatable {
  const SetOutOfOfficeParams({
    required this.accountId,
    required this.settings,
  });

  final String accountId;
  final OutOfOfficeSettings settings;

  @override
  List<Object?> get props => [accountId, settings];
}
