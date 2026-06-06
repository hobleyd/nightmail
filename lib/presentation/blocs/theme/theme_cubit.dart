import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import 'theme_state.dart';

class ThemeCubit extends Cubit<ThemeState> {
  ThemeCubit() : super(const ThemeState(mode: AppThemeMode.system));

  static const _fileName = 'theme_pref';

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final value = (await file.readAsString()).trim();
        emit(ThemeState(
          mode: switch (value) {
            'light' => AppThemeMode.light,
            'dark' => AppThemeMode.dark,
            _ => AppThemeMode.system,
          },
        ));
      }
    } catch (_) {
      // Default to system on any I/O error.
    }
  }

  Future<void> setMode(AppThemeMode mode) async {
    emit(ThemeState(mode: mode));
    try {
      final file = await _file();
      await file.writeAsString(mode.name);
    } catch (_) {}
  }
}
