import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/out_of_office_settings.dart';
import '../repositories/out_of_office_repository.dart';

class GetOutOfOffice implements UseCase<OutOfOfficeSettings, String> {
  const GetOutOfOffice(this._repository);

  final OutOfOfficeRepository _repository;

  @override
  Future<Either<Failure, OutOfOfficeSettings>> call(String accountId) =>
      _repository.getOutOfOffice(accountId);
}
