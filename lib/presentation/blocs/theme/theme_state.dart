import 'package:equatable/equatable.dart';

enum AppThemeMode { system, light, dark }

class ThemeState extends Equatable {
  const ThemeState({required this.mode});

  final AppThemeMode mode;

  @override
  List<Object?> get props => [mode];
}
