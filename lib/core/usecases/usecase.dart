import 'package:fpdart/fpdart.dart';
import '../error/failures.dart';

abstract interface class UseCase<Output, Params> {
  Future<Either<Failure, Output>> call(Params params);
}

/// Marker class for use cases that take no parameters.
final class NoParams {
  const NoParams();
}
