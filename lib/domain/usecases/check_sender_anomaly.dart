import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../../core/utils/jaro_winkler.dart';
import '../repositories/sender_repository.dart';

const _anomalyThreshold = 0.85;

class SenderAnomalyResult extends Equatable {
  const SenderAnomalyResult({required this.score, required this.matches});

  final double score;

  /// Known senders whose display name is similar to the incoming name but
  /// whose address differs — the addresses the user has actually seen before.
  final List<({String address, String name})> matches;

  @override
  List<Object?> get props => [score, matches];
}

class CheckSenderAnomaly
    implements UseCase<SenderAnomalyResult?, CheckSenderAnomalyParams> {
  const CheckSenderAnomaly(this._repository);

  final SenderRepository _repository;

  /// Returns all known senders whose display name matches [fromName] above
  /// [_anomalyThreshold] but whose address differs from [fromAddress].
  /// Returns null when no anomaly is detected.
  @override
  Future<Either<Failure, SenderAnomalyResult?>> call(
      CheckSenderAnomalyParams params) async {
    try {
      final senders = await _repository.getSendersForAccount(params.accountId);
      final incomingAddress = params.fromAddress.toLowerCase();
      final incomingName = params.fromName;

      var best = 0.0;
      final seenAddresses = <String>{};
      final matches = <({String address, String name})>[];

      for (final sender in senders) {
        if (sender.address == incomingAddress) continue;
        final score = jaroWinkler(incomingName, sender.name);
        if (score >= _anomalyThreshold) {
          if (seenAddresses.add(sender.address)) {
            matches.add((address: sender.address, name: sender.name));
          }
          if (score > best) best = score;
        }
      }

      if (matches.isEmpty) return const Right(null);
      return Right(SenderAnomalyResult(score: best, matches: matches));
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
