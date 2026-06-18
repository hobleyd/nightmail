import 'package:equatable/equatable.dart';

enum AppThemeMode { system, light, dark }

class ThemeState extends Equatable {
  const ThemeState({
    required this.mode,
    this.fontFamily,
    this.fontScale = 1.0,
  });

  final AppThemeMode mode;
  final String? fontFamily;
  final double fontScale;

  ThemeState copyWith({
    AppThemeMode? mode,
    Object? fontFamily = _unset,
    double? fontScale,
  }) {
    return ThemeState(
      mode: mode ?? this.mode,
      fontFamily: fontFamily == _unset ? this.fontFamily : fontFamily as String?,
      fontScale: fontScale ?? this.fontScale,
    );
  }

  @override
  List<Object?> get props => [mode, fontFamily, fontScale];
}

const _unset = Object();
