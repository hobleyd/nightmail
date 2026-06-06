class AppConfig {
  const AppConfig._();

  static const microsoftClientId = String.fromEnvironment(
    'AZURE_CLIENT_ID',
    defaultValue: 'YOUR_CLIENT_ID',
  );
  static const microsoftTenantId = String.fromEnvironment(
    'AZURE_TENANT_ID',
    defaultValue: 'common',
  );
  static const microsoftRedirectUri = String.fromEnvironment(
    'AZURE_REDIRECT_URI',
    defaultValue: 'nightmail://auth-callback',
  );

  static const gmailClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
    defaultValue: 'YOUR_GOOGLE_CLIENT_ID',
  );
  static const gmailRedirectUri = String.fromEnvironment(
    'GOOGLE_REDIRECT_URI',
    defaultValue: 'nightmail://google-auth-callback',
  );
}
