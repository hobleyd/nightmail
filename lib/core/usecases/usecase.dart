import 'package:fpdart/fpdart.dart';
import '../error/failures.dart';

abstract interface class UseCase<Type, Params> {
  Future<Either<Failure, Type>> call(Params params);
}

/// Marker class for use cases that take no parameters.
final class NoParams {
  const NoParams();
}
