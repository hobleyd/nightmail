import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../../core/utils/jaro_winkler.dart';
import '../repositories/sender_repository.dart';

const _anomalyThreshold = 0.75;

class CheckSenderAnomaly implements UseCase<double?, CheckSenderAnomalyParams> {
  const CheckSenderAnomaly(this._repository);

  final SenderRepository _repository;

  /// Returns the highest Jaro-Winkler score among known senders whose name
  /// matches [fromName] but whose address differs from [fromAddress].
  /// Returns null when no anomaly is detected (score below threshold or
  /// address already known for this name).
  @override
  Future<Either<Failure, double?>> call(
      CheckSenderAnomalyParams params) async {
    try {
      final senders = await _repository.getSendersForAccount(params.accountId);
      final incomingAddress = params.fromAddress.toLowerCase();
      final incomingName = params.fromName;

      var best = 0.0;
      for (final sender in senders) {
        if (sender.address == incomingAddress) continue;
        final score = jaroWinkler(incomingName, sender.name);
        if (score > best) best = score;
      }

      return Right(best >= _anomalyThreshold ? best : null);
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }
}

class CheckSenderAnomalyParams extends Equatable {
  const CheckSenderAnomalyParams({
    required this.accountId,
    required this.fromAddress,
    required this.fromName,
  });

  final String accountId;
  final String fromAddress;
  final String fromName;

  @override
  List<Object?> get props => [accountId, fromAddress, fromName];
}
