class OAuthCredentials {
  const OAuthCredentials({
    required this.microsoftClientId,
    required this.microsoftTenantId,
    required this.microsoftRedirectUri,
    required this.googleClientId,
    required this.googleRedirectUri,
  });

  final String microsoftClientId;
  final String microsoftTenantId;
  final String microsoftRedirectUri;
  final String googleClientId;
  final String googleRedirectUri;

  OAuthCredentials copyWith({
    String? microsoftClientId,
    String? microsoftTenantId,
    String? microsoftRedirectUri,
    String? googleClientId,
    String? googleRedirectUri,
  }) => OAuthCredentials(
        microsoftClientId: microsoftClientId ?? this.microsoftClientId,
        microsoftTenantId: microsoftTenantId ?? this.microsoftTenantId,
        microsoftRedirectUri: microsoftRedirectUri ?? this.microsoftRedirectUri,
        googleClientId: googleClientId ?? this.googleClientId,
        googleRedirectUri: googleRedirectUri ?? this.googleRedirectUri,
      );
}
