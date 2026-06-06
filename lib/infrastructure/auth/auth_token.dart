import 'package:equatable/equatable.dart';

class AuthToken extends Equatable {
  const AuthToken({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
    this.tokenType = 'Bearer',
    this.scope,
  });

  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;
  final String tokenType;
  final String? scope;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get isAboutToExpire =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 5)));

  factory AuthToken.fromJson(Map<String, dynamic> json) {
    final expiresIn = json['expires_in'] as int? ?? 3600;
    return AuthToken(
      accessToken: json['access_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      refreshToken: json['refresh_token'] as String?,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      scope: json['scope'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'expires_at': expiresAt.toIso8601String(),
        'refresh_token': refreshToken,
        'token_type': tokenType,
        'scope': scope,
      };

  factory AuthToken.fromStorageJson(Map<String, dynamic> json) {
    return AuthToken(
      accessToken: json['access_token'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
      refreshToken: json['refresh_token'] as String?,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      scope: json['scope'] as String?,
    );
  }

  @override
  List<Object?> get props => [accessToken, expiresAt];
}
