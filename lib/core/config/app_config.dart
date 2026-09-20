import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

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
  static const _gmailClientIdDesktop = String.fromEnvironment(
    'GOOGLE_CLIENT_ID',
    defaultValue: 'YOUR_GOOGLE_CLIENT_ID',
  );
  static const gmailClientSecret = String.fromEnvironment(
    'GOOGLE_CLIENT_SECRET',
    defaultValue: '',
  );

  // iOS and Android each need their own Google OAuth client (see
  // gmailRedirectUri below and lib/infrastructure/auth/CLAUDE.md) — and
  // Android's differs again between a local debug build and the CI-signed
  // release build, since Google ties each client to one signing
  // certificate's SHA-1 fingerprint. Falls back to the Desktop client's ID
  // (or the placeholder) on every other platform, and whenever a
  // platform-specific value hasn't been supplied — e.g. for anyone building
  // this app from source without their own Android/iOS clients, the sign-in
  // dialog then just asks for a Client ID directly instead of silently
  // sending one that won't work.
  static const _gmailClientIdAndroidDebug = String.fromEnvironment(
    'GOOGLE_CLIENT_ID_ANDROID_DEBUG',
  );
  static const _gmailClientIdAndroidRelease = String.fromEnvironment(
    'GOOGLE_CLIENT_ID_ANDROID_RELEASE',
  );
  static const _gmailClientIdIos = String.fromEnvironment(
    'GOOGLE_CLIENT_ID_IOS',
  );

  static String get gmailClientId {
    if (!kIsWeb && Platform.isIOS && _gmailClientIdIos.isNotEmpty) {
      return _gmailClientIdIos;
    }
    if (!kIsWeb && Platform.isAndroid) {
      final id = kReleaseMode
          ? _gmailClientIdAndroidRelease
          : _gmailClientIdAndroidDebug;
      if (id.isNotEmpty) return id;
    }
    return _gmailClientIdDesktop;
  }
  static const _gmailRedirectUriOverride = String.fromEnvironment(
    'GOOGLE_REDIRECT_URI',
  );

  // Google requires a custom-scheme redirect to be reverse-DNS shaped (a
  // period in the scheme, a single-slash path) on both iOS and Android — a
  // bare scheme like `nightmail://...` is rejected outright on either,
  // verified directly against both real OAuth clients (enabling Android's
  // "custom URI scheme" advanced setting alone was not enough). The
  // loopback-based desktop platforms ignore this value entirely (see
  // GmailAuthService._effectiveRedirectUri) so it's harmless to leave them on
  // the dotted scheme too. See lib/infrastructure/auth/CLAUDE.md for how this
  // was diagnosed.
  static String get gmailRedirectUri {
    if (_gmailRedirectUriOverride.isNotEmpty) return _gmailRedirectUriOverride;
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      return 'au.com.sharpblue.nightmail:/google-auth-callback';
    }
    return 'nightmail://google-auth-callback';
  }
}
