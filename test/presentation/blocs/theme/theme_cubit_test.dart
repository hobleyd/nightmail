import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/presentation/blocs/theme/theme_cubit.dart';
import 'package:nightmail/presentation/blocs/theme/theme_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Points `appDataDirectory()` at a real temp directory rather than the
/// developer's home — same shape as account_manager_test.dart's fake, but
/// backed by a fresh temp dir per test instead of '.', since ThemeCubit
/// really does read the files back (account_manager_test.dart never exercises
/// that path, so it can get away with a constant).
class _FakePathProviderPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProviderPlatform(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ThemeCubit cubit;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('theme_cubit_test');
    // Not under $HOME/Library/, so appDataDirectory()'s macOS redirect leaves
    // it alone and this temp dir is used verbatim — see app_data_directory.dart.
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    cubit = ThemeCubit();
  });

  tearDown(() {
    cubit.close();
    tempDir.deleteSync(recursive: true);
  });

  test('starts on system mode with no font override', () {
    expect(cubit.state.mode, AppThemeMode.system);
    expect(cubit.state.fontFamily, isNull);
    expect(cubit.state.fontScale, 1.0);
  });

  group('load', () {
    test('leaves the defaults when nothing has ever been saved', () async {
      await cubit.load();

      expect(cubit.state.mode, AppThemeMode.system);
      expect(cubit.state.fontFamily, isNull);
      expect(cubit.state.fontScale, 1.0);
    });

    test('reads back a previously saved mode, font family and scale',
        () async {
      File('${tempDir.path}/theme_pref').writeAsStringSync('dark');
      File('${tempDir.path}/theme_font_family').writeAsStringSync('Georgia');
      File('${tempDir.path}/theme_font_scale').writeAsStringSync('1.25');

      await cubit.load();

      expect(cubit.state.mode, AppThemeMode.dark);
      expect(cubit.state.fontFamily, 'Georgia');
      expect(cubit.state.fontScale, 1.25);
    });

    test('an unrecognised mode value falls back to system', () async {
      File('${tempDir.path}/theme_pref').writeAsStringSync('sepia');

      await cubit.load();

      expect(cubit.state.mode, AppThemeMode.system);
    });

    test('an empty font family file reads back as no override', () async {
      File('${tempDir.path}/theme_font_family').writeAsStringSync('');

      await cubit.load();

      expect(cubit.state.fontFamily, isNull);
    });

    test('an unparseable font scale falls back to 1.0', () async {
      File('${tempDir.path}/theme_font_scale').writeAsStringSync('huge');

      await cubit.load();

      expect(cubit.state.fontScale, 1.0);
    });
  });

  group('setMode', () {
    test('updates state immediately and persists it', () async {
      await cubit.setMode(AppThemeMode.dark);

      expect(cubit.state.mode, AppThemeMode.dark);
      expect(
        File('${tempDir.path}/theme_pref').readAsStringSync(),
        'dark',
      );
    });

    test('round-trips through a second cubit\'s load', () async {
      await cubit.setMode(AppThemeMode.light);

      final other = ThemeCubit();
      addTearDown(other.close);
      await other.load();

      expect(other.state.mode, AppThemeMode.light);
    });
  });

  group('setFontFamily', () {
    test('updates state immediately and persists it', () async {
      await cubit.setFontFamily('Menlo');

      expect(cubit.state.fontFamily, 'Menlo');
      expect(
        File('${tempDir.path}/theme_font_family').readAsStringSync(),
        'Menlo',
      );
    });

    test('clearing it back to null persists an empty file', () async {
      await cubit.setFontFamily('Menlo');
      await cubit.setFontFamily(null);

      expect(cubit.state.fontFamily, isNull);
      expect(
        File('${tempDir.path}/theme_font_family').readAsStringSync(),
        '',
      );
    });
  });

  group('setFontScale', () {
    test('updates state immediately and persists it', () async {
      await cubit.setFontScale(1.5);

      expect(cubit.state.fontScale, 1.5);
      expect(
        File('${tempDir.path}/theme_font_scale').readAsStringSync(),
        '1.5',
      );
    });
  });
}
