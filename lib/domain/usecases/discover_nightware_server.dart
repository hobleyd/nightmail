import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/graph_endpoints.dart';
import '../repositories/server_discovery_repository.dart';

/// Resolves a NightMail Server address to the endpoints its account signs in
/// and syncs against. Params: the address as the user typed it.
class DiscoverNightwareServer implements UseCase<GraphEndpoints, String> {
  const DiscoverNightwareServer(this._repository);

  final ServerDiscoveryRepository _repository;

  @override
  Future<Either<Failure, GraphEndpoints>> call(String params) =>
      _repository.discover(params);
}
