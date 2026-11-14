import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/graph_endpoints.dart';

/// Learns where a NightMail Server's Graph API and sign-in live, from the
/// address the user typed when adding the account.
abstract interface class ServerDiscoveryRepository {
  /// [ServerFailure] when [serverUrl] is not a usable NightMail Server (bad
  /// address, non-2xx answer, malformed configuration), [NetworkFailure] when
  /// it could not be reached.
  Future<Either<Failure, GraphEndpoints>> discover(String serverUrl);
}
