class AppConfig {
  const AppConfig._();

  static const microsoftClientId = String.fromEnvironment(
    'AZURE_CLIENT_ID',
    defaultValue: 'YOUR_CLIENT_ID',
  );
  static const microsoftTenantId = String.fromEnvironment(
    'AZURE_TENANT_ID',
    defaultValue: '5a4c10f6-4474-4f1a-99db-8cecac7c3099',
  );
  static const microsoftRedirectUri = String.fromEnvironment(
    'AZURE_REDIRECT_URI',
    defaultValue: 'nightmail://auth-callback',
  );

  // No literal default: GitHub push protection blocks a Google OAuth Client
  // ID/Secret pair committed to source, even a non-confidential "Desktop
  // app"-type one (see Google's native-app OAuth docs). Supply the real
  // values at build time via --dart-define, e.g. in the release pipeline —
  // never hardcode them here.
  static const gmailClientId = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
    defaultValue: 'YOUR_GOOGLE_CLIENT_ID',
  );
  static const gmailClientSecret = String.fromEnvironment(
    'GOOGLE_CLIENT_SECRET',
    defaultValue: '',
  );
  static const gmailRedirectUri = String.fromEnvironment(
    'GOOGLE_REDIRECT_URI',
    defaultValue: 'nightmail://google-auth-callback',
  );
}
