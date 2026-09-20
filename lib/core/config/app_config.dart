import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  const AppConfig._();

  static const microsoftClientId = String.fromEnvironment(
    'AZURE_CLIENT_ID',
    defaultValue: 'YOUR_CLIENT_ID',
  );
  // No org-specific literal default here either, for the same reason as the
  // Google credentials below: supply our tenant via --dart-define at build
  // time rather than committing it to source. 'common' (any tenant/personal
  // account) is the generic, provider-agnostic fallback for anyone else
  // building this app.
  static const microsoftTenantId = String.fromEnvironment(
    'AZURE_TENANT_ID',
    defaultValue: 'common',
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
  static const _gmailRedirectUriOverride = String.fromEnvironment(
    'GOOGLE_REDIRECT_URI',
  );

  // Google requires a custom-scheme redirect on iOS to be reverse-DNS shaped
  // (a period in the scheme, a single-slash path) — a bare scheme like
  // `nightmail://...` is rejected outright. Android and the loopback-based
  // desktop platforms keep the plain scheme. See
  // lib/infrastructure/auth/CLAUDE.md for how this was diagnosed.
  static String get gmailRedirectUri {
    if (_gmailRedirectUriOverride.isNotEmpty) return _gmailRedirectUriOverride;
    if (!kIsWeb && Platform.isIOS) {
      return 'au.com.sharpblue.nightmail:/google-auth-callback';
    }
    return 'nightmail://google-auth-callback';
  }
}
