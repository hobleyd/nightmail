class ServerException implements Exception {
  const ServerException({required this.message, this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ServerException($statusCode): $message';
}

class AuthException implements Exception {
  const AuthException({required this.message});
  final String message;

  @override
  String toString() => 'AuthException: $message';
}

class CacheException implements Exception {
  const CacheException({required this.message});
  final String message;

  @override
  String toString() => 'CacheException: $message';
}

class NetworkException implements Exception {
  const NetworkException({required this.message});
  final String message;

  @override
  String toString() => 'NetworkException: $message';
}
