import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/sender_repository.dart';

class MergeSenderAddresses
    implements UseCase<void, MergeSenderAddressesParams> {
  const MergeSenderAddresses(this._repository);

  final SenderRepository _repository;

  @override
  Future<Either<Failure, void>> call(MergeSenderAddressesParams params) async {
    try {
      await _repository.mergeSenders(
        accountId: params.accountId,
        address1: params.address1,
        address2: params.address2,
      );
      return const Right(null);
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }
}

class MergeSenderAddressesParams extends Equatable {
  const MergeSenderAddressesParams({
    required this.accountId,
    required this.address1,
    required this.address2,
  });

  final String accountId;
  final String address1;
  final String address2;

  @override
  List<Object?> get props => [accountId, address1, address2];
}
