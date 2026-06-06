import 'package:equatable/equatable.dart';

sealed class Failure extends Equatable {
  const Failure({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}

final class ServerFailure extends Failure {
  const ServerFailure({required super.message, this.statusCode});
  final int? statusCode;

  @override
  List<Object?> get props => [message, statusCode];
}

final class AuthFailure extends Failure {
  const AuthFailure({required super.message});
}

final class NetworkFailure extends Failure {
  const NetworkFailure({required super.message});
}

final class CacheFailure extends Failure {
  const CacheFailure({required super.message});
}
