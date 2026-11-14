import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/graph_endpoints.dart';
import '../../domain/repositories/server_discovery_repository.dart';
import '../datasources/remote/nightware_discovery_datasource.dart';

class ServerDiscoveryRepositoryImpl implements ServerDiscoveryRepository {
  const ServerDiscoveryRepositoryImpl({required this._datasource});

  final NightwareDiscoveryDatasource _datasource;

  @override
  Future<Either<Failure, GraphEndpoints>> discover(String serverUrl) async {
    try {
      return Right(await _datasource.discover(serverUrl));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    }
  }
}
