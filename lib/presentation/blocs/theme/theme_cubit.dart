import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import 'theme_state.dart';

class ThemeCubit extends Cubit<ThemeState> {
  ThemeCubit() : super(const ThemeState(mode: AppThemeMode.system));

  static const _modeFile = 'theme_pref';
  static const _fontFamilyFile = 'theme_font_family';
  static const _fontScaleFile = 'theme_font_scale';

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<void> load() async {
    try {
      AppThemeMode mode = AppThemeMode.system;
      String? fontFamily;
      double fontScale = 1.0;

      final modeFile = await _file(_modeFile);
      if (await modeFile.exists()) {
        final value = (await modeFile.readAsString()).trim();
        mode = switch (value) {
          'light' => AppThemeMode.light,
          'dark' => AppThemeMode.dark,
          _ => AppThemeMode.system,
        };
      }

      final familyFile = await _file(_fontFamilyFile);
      if (await familyFile.exists()) {
        final value = (await familyFile.readAsString()).trim();
        fontFamily = value.isEmpty ? null : value;
      }

      final scaleFile = await _file(_fontScaleFile);
      if (await scaleFile.exists()) {
        final value = (await scaleFile.readAsString()).trim();
        fontScale = double.tryParse(value) ?? 1.0;
      }

      emit(ThemeState(mode: mode, fontFamily: fontFamily, fontScale: fontScale));
    } catch (_) {}
  }

  Future<void> setMode(AppThemeMode mode) async {
    emit(state.copyWith(mode: mode));
    try {
      await (await _file(_modeFile)).writeAsString(mode.name);
    } catch (_) {}
  }

  Future<void> setFontFamily(String? fontFamily) async {
    emit(state.copyWith(fontFamily: fontFamily));
    try {
      await (await _file(_fontFamilyFile)).writeAsString(fontFamily ?? '');
    } catch (_) {}
  }

  Future<void> setFontScale(double scale) async {
    emit(state.copyWith(fontScale: scale));
    try {
      await (await _file(_fontScaleFile)).writeAsString('$scale');
    } catch (_) {}
  }
}
