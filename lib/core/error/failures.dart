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

/// Base type for failures originating from the AI subsystem.
sealed class AiFailure extends Failure {
  const AiFailure({required super.message});
}

/// No provider/model has been selected for the requested capability.
final class NoProviderConfigured extends AiFailure {
  const NoProviderConfigured({required super.message});
}

/// The selected provider requires an API key, but none is stored.
final class MissingApiKey extends AiFailure {
  const MissingApiKey({required super.message});
}

/// The provider could not be reached (network down / local server offline).
final class ProviderUnreachable extends AiFailure {
  const ProviderUnreachable({required super.message});
}

/// The provider returned a rate-limit response (HTTP 429).
final class RateLimited extends AiFailure {
  const RateLimited({required super.message});
}

/// The request exceeds the model's context window (per catalog metadata).
final class ContextTooLong extends AiFailure {
  const ContextTooLong({required super.message});
}

/// The model catalog could not be fetched and no cached copy is available.
final class CatalogUnavailable extends AiFailure {
  const CatalogUnavailable({required super.message});
}
