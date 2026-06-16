class OAuthCredentials {
  const OAuthCredentials({
    required this.microsoftClientId,
    required this.microsoftTenantId,
    required this.microsoftRedirectUri,
    required this.googleClientId,
    required this.googleRedirectUri,
    this.microsoftClientSecret,
    this.googleClientSecret,
  });

  final String microsoftClientId;
  final String microsoftTenantId;
  final String microsoftRedirectUri;
  final String googleClientId;
  final String googleRedirectUri;
  final String? microsoftClientSecret;
  final String? googleClientSecret;

  // Sentinel so copyWith can distinguish "caller passed null" from "not passed".
  static const _unset = Object();

  OAuthCredentials copyWith({
    String? microsoftClientId,
    String? microsoftTenantId,
    String? microsoftRedirectUri,
    String? googleClientId,
    String? googleRedirectUri,
    Object? microsoftClientSecret = _unset,
    Object? googleClientSecret = _unset,
  }) =>
      OAuthCredentials(
        microsoftClientId: microsoftClientId ?? this.microsoftClientId,
        microsoftTenantId: microsoftTenantId ?? this.microsoftTenantId,
        microsoftRedirectUri: microsoftRedirectUri ?? this.microsoftRedirectUri,
        googleClientId: googleClientId ?? this.googleClientId,
        googleRedirectUri: googleRedirectUri ?? this.googleRedirectUri,
        microsoftClientSecret: microsoftClientSecret == _unset
            ? this.microsoftClientSecret
            : microsoftClientSecret as String?,
        googleClientSecret: googleClientSecret == _unset
            ? this.googleClientSecret
            : googleClientSecret as String?,
      );
}
