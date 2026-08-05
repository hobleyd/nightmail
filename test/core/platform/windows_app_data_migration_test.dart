import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/platform/windows_app_data_migration.dart';

void main() {
  late Directory root;
  late Directory from;
  late Directory to;

  setUp(() {
    root = Directory.systemTemp.createTempSync('appdata_migration_test');
    from = Directory('${root.path}/com.sharpblue/NightMail')
      ..createSync(recursive: true);
    to = Directory('${root.path}/au.com.sharpblue/NightMail');
  });

  tearDown(() => root.deleteSync(recursive: true));

  String read(Directory dir, String name) =>
      File('${dir.path}/$name').readAsStringSync();

  group('mergeAppDataInto', () {
    test('moves credentials and settings into a destination that does not '
        'exist yet', () {
      File('${from.path}/flutter_secure_storage.dat').writeAsStringSync('creds');
      File('${from.path}/window_bounds.json').writeAsStringSync('{}');

      mergeAppDataInto(from, to);

      expect(read(to, 'flutter_secure_storage.dat'), 'creds');
      expect(read(to, 'window_bounds.json'), '{}');
      expect(File('${from.path}/flutter_secure_storage.dat').existsSync(),
          isFalse);
    });

    test('keeps the destination copy when both sides have the same file', () {
      File('${from.path}/confirm_delete_email').writeAsStringSync('old');
      to.createSync(recursive: true);
      File('${to.path}/confirm_delete_email').writeAsStringSync('new');

      mergeAppDataInto(from, to);

      expect(read(to, 'confirm_delete_email'), 'new');
    });

    test('merges nested directories rather than replacing them', () {
      Directory('${from.path}/inline/a').createSync(recursive: true);
      File('${from.path}/inline/a/one.png').writeAsStringSync('1');
      Directory('${to.path}/inline/b').createSync(recursive: true);
      File('${to.path}/inline/b/two.png').writeAsStringSync('2');

      mergeAppDataInto(from, to);

      expect(File('${to.path}/inline/a/one.png').existsSync(), isTrue);
      expect(File('${to.path}/inline/b/two.png').existsSync(), isTrue);
    });

    test('creates the destination even when the source is empty', () {
      mergeAppDataInto(from, to);

      expect(to.existsSync(), isTrue);
    });
  });
}

// migrateWindowsAppDataDirectory() itself is deliberately not exercised here:
// on a Windows dev machine it resolves the real %APPDATA% and would move the
// developer's own accounts. mergeAppDataInto is the part with the logic.
