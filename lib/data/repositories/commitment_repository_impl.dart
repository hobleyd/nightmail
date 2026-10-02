import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../domain/entities/commitment.dart';
import '../../domain/repositories/commitment_repository.dart';
import '../datasources/local/commitment_local_datasource.dart';

/// [CommitmentRepository] over the drift-backed [CommitmentLocalDatasource].
/// Purely local: the ledger is derived from mail already in the cache, so
/// there is nothing to fetch and every failure is a [CacheFailure].
class CommitmentRepositoryImpl implements CommitmentRepository {
  const CommitmentRepositoryImpl(this._local);

  final CommitmentLocalDatasource _local;

  @override
  Future<Either<Failure, List<Commitment>>> getCommitments({
    required String accountId,
  }) =>
      _guard(() => _local.getCommitments(accountId));

  @override
  Future<Either<Failure, Unit>> saveCommitments(
    List<Commitment> commitments,
  ) =>
      _guard(() async {
        await _local.upsertCommitments(commitments);
        return unit;
      });

  @override
  Future<Either<Failure, Unit>> setStatus({
    required String accountId,
    required String id,
    required CommitmentStatus status,
    required DateTime now,
  }) =>
      _guard(() async {
        await _local.setStatus(
          accountId: accountId,
          id: id,
          status: status,
          now: now,
        );
        return unit;
      });

  @override
  Future<Either<Failure, Unit>> setSchedule({
    required String accountId,
    required String id,
    required String eventId,
    required DateTime start,
    required DateTime end,
  }) =>
      _guard(() async {
        await _local.setSchedule(
          accountId: accountId,
          id: id,
          eventId: eventId,
          start: start,
          end: end,
        );
        return unit;
      });

  @override
  Future<Either<Failure, Set<String>>> getScannedEmailIds({
    required String accountId,
  }) =>
      _guard(() => _local.getScannedEmailIds(accountId));

  @override
  Future<Either<Failure, Unit>> markScanned({
    required String accountId,
    required Iterable<String> emailIds,
    required DateTime now,
  }) =>
      _guard(() async {
        await _local.markScanned(
          accountId: accountId,
          emailIds: emailIds,
          now: now,
        );
        return unit;
      });

  Future<Either<Failure, T>> _guard<T>(Future<T> Function() body) async {
    try {
      return Right(await body());
    } catch (e) {
      return Left(CacheFailure(message: 'Commitment ledger error: $e'));
    }
  }
}
