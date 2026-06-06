import 'package:flutter/material.dart';

extension AppColorsX on BuildContext {
  AppColors get colors => AppColors(Theme.of(this).brightness);
}

class AppColors {
  const AppColors(this._brightness);
  final Brightness _brightness;
  bool get _isDark => _brightness == Brightness.dark;

  static const Color accent = Color(0xFF7C83FD);

  // Surfaces
  Color get surfaceBase => _isDark ? const Color(0xFF0F1117) : const Color(0xFFF5F6FA);
  Color get surfacePanel => _isDark ? const Color(0xFF13161F) : Colors.white;
  Color get surfaceReading => _isDark ? const Color(0xFF0D0F17) : const Color(0xFFFAFAFC);

  // Text hierarchy (most prominent → least prominent)
  Color get textPrimary => _isDark ? Colors.white : const Color(0xFF111827);
  Color get textSecondary => _isDark ? const Color(0xFFE0E0E0) : const Color(0xFF374151);
  Color get textBody => _isDark ? const Color(0xFFD1D5DB) : const Color(0xFF374151);
  Color get textTertiary => _isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);
  Color get textMuted => _isDark ? const Color(0xFF6B7280) : const Color(0xFF9CA3AF);
  Color get textDimmed => _isDark ? const Color(0xFF4B5563) : const Color(0xFF9CA3AF);

  // HTML color strings for HtmlWidget customStylesBuilder
  String get textBodyHtml => _isDark ? '#D1D5DB' : '#374151';

  // Separators & borders
  Color get separator => _isDark ? const Color(0xFF1E2130) : const Color(0xFFE5E7EB);
  Color get separatorStrong => _isDark ? const Color(0xFF2A2D3E) : const Color(0xFFD1D5DB);
  Color get border => _isDark ? const Color(0xFF1A1D27) : const Color(0xFFE5E7EB);

  // Accent-based selection states (same in both themes)
  Color get selectionBg => accent.withAlpha(30);
  Color get selectionEmailBg => accent.withAlpha(25);
  Color get selectionBorder => accent.withAlpha(80);
  Color get badgeBg => accent.withAlpha(40);

  // Empty/error states
  Color get stateIcon => _isDark ? const Color(0xFF1E2130) : const Color(0xFFDFE3EA);
  Color get stateText => _isDark ? const Color(0xFF374151) : const Color(0xFF9CA3AF);

  // Sign-in page
  Color get logoContainerBg => _isDark ? const Color(0xFF1A1D27) : const Color(0xFFF3F4F6);
  Color get logoContainerBorder => _isDark ? const Color(0xFF2A2D3E) : const Color(0xFFE5E7EB);
  Color get errorBannerBg => _isDark ? const Color(0xFF2D1B1B) : const Color(0xFFFEF2F2);
  Color get errorBannerBorder => _isDark ? const Color(0xFF5C2626) : const Color(0xFFFCA5A5);
  Color get errorBannerText => _isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C);
}
