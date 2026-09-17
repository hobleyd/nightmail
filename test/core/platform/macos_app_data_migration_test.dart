import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/platform/macos_app_data_migration.dart';

void main() {
  late Directory root;
  late Directory containerSupport;
  late Directory librarySupport;
  late Directory containerDocuments;
  late Directory userDocuments;
  late Directory destination;

  setUp(() {
    root = Directory.systemTemp.createTempSync('macos_appdata_migration_test');
    containerSupport = Directory('${root.path}/container/support');
    librarySupport = Directory('${root.path}/library/support');
    containerDocuments = Directory('${root.path}/container/documents');
    userDocuments = Directory('${root.path}/home/Documents');
    destination = Directory('${root.path}/home/.nightmail');
    for (final dir in [
      containerSupport,
      librarySupport,
      containerDocuments,
      userDocuments,
    ]) {
      dir.createSync(recursive: true);
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(Directory dir, String name, String contents) =>
      File('${dir.path}/$name').writeAsStringSync(contents);

  String read(Directory dir, String name) =>
      File('${dir.path}/$name').readAsStringSync();

  bool has(Directory dir, String name) => File('${dir.path}/$name').existsSync();

  void migrate() => adoptMacOSAppData(
        supportDirectories: [containerSupport, librarySupport],
        databaseDirectories: [containerDocuments, userDocuments],
        takeDatabaseFrom: userDocuments,
        destination: destination,
      );

  group('copyAppDataInto', () {
    test('copies a tree into a destination that does not exist yet', () {
      write(containerSupport, 'window_bounds.json', '{}');
      Directory('${containerSupport.path}/nested').createSync();
      write(Directory('${containerSupport.path}/nested'), 'rules', 'spam');

      copyAppDataInto(containerSupport, destination);

      expect(read(destination, 'window_bounds.json'), '{}');
      expect(read(Directory('${destination.path}/nested'), 'rules'), 'spam');
    });

    test('leaves the source in place — unlike the Windows move, both paths '
        'stay readable and the old one is the way back', () {
      write(containerSupport, 'confirm_delete_email', 'true');

      copyAppDataInto(containerSupport, destination);

      expect(has(containerSupport, 'confirm_delete_email'), isTrue);
    });

    test('keeps the destination copy when both sides have the same file', () {
      write(containerSupport, 'confirm_delete_email', 'old');
      destination.createSync(recursive: true);
      write(destination, 'confirm_delete_email', 'new');

      copyAppDataInto(containerSupport, destination);

      expect(read(destination, 'confirm_delete_email'), 'new');
    });

    test('is a no-op for a source that was never there', () {
      copyAppDataInto(Directory('${root.path}/absent'), destination);

      expect(destination.existsSync(), isFalse);
    });
  });

  group('adoptDatabase', () {
    test('takes the write-ahead log with the database', () {
      write(containerDocuments, 'nightmail_cache.sqlite', 'db');
      write(containerDocuments, 'nightmail_cache.sqlite-wal', 'wal');

      expect(adoptDatabase(containerDocuments, destination), isTrue);

      expect(read(destination, 'nightmail_cache.sqlite'), 'db');
      expect(read(destination, 'nightmail_cache.sqlite-wal'), 'wal');
    });

    test('leaves the -shm behind, since SQLite rebuilds it from the log', () {
      write(containerDocuments, 'nightmail_cache.sqlite', 'db');
      write(containerDocuments, 'nightmail_cache.sqlite-shm', 'shm');

      adoptDatabase(containerDocuments, destination);

      expect(has(destination, 'nightmail_cache.sqlite-shm'), isFalse);
    });

    test('refuses a destination that already has a database, which is what '
        'makes a second launch a no-op', () {
      write(containerDocuments, 'nightmail_cache.sqlite', 'old');
      destination.createSync(recursive: true);
      write(destination, 'nightmail_cache.sqlite', 'current');

      expect(adoptDatabase(containerDocuments, destination), isFalse);
      expect(read(destination, 'nightmail_cache.sqlite'), 'current');
    });

    test('reports nothing adopted when the source has no database', () {
      expect(adoptDatabase(containerDocuments, destination), isFalse);
    });
  });

  group('adoptMacOSAppData', () {
    test('merges both support directories, container first', () {
      write(containerSupport, 'active_view', 'mail');
      write(librarySupport, 'active_view', 'calendar');
      write(librarySupport, 'external_image_domains', 'example.com');

      migrate();

      expect(read(destination, 'active_view'), 'mail');
      expect(read(destination, 'external_image_domains'), 'example.com');
    });

    test('prefers the container database over the one in Documents', () {
      write(containerDocuments, 'nightmail_cache.sqlite', 'release');
      write(userDocuments, 'nightmail_cache.sqlite', 'debug');

      migrate();

      expect(read(destination, 'nightmail_cache.sqlite'), 'release');
    });

    test('leaves the container database where it is', () {
      write(containerDocuments, 'nightmail_cache.sqlite', 'release');

      migrate();

      expect(has(containerDocuments, 'nightmail_cache.sqlite'), isTrue);
    });

    test('takes the one in Documents away, because a file of ours in the '
        "user's own folder is what ~/.nightmail exists to stop", () {
      write(userDocuments, 'nightmail_cache.sqlite', 'debug');
      write(userDocuments, 'nightmail_cache.sqlite-wal', 'wal');
      write(userDocuments, 'nightmail_cache.sqlite-shm', 'shm');

      migrate();

      expect(read(destination, 'nightmail_cache.sqlite'), 'debug');
      expect(has(userDocuments, 'nightmail_cache.sqlite'), isFalse);
      expect(has(userDocuments, 'nightmail_cache.sqlite-wal'), isFalse);
      expect(has(userDocuments, 'nightmail_cache.sqlite-shm'), isFalse);
    });

    test('touches nothing in Documents but the database', () {
      write(userDocuments, 'nightmail_cache.sqlite', 'debug');
      write(userDocuments, 'a-real-document.txt', 'mine');

      migrate();

      expect(has(userDocuments, 'a-real-document.txt'), isTrue);
      expect(has(destination, 'a-real-document.txt'), isFalse);
    });

    test('running twice changes nothing the second time', () {
      write(containerSupport, 'active_view', 'mail');
      write(containerDocuments, 'nightmail_cache.sqlite', 'release');

      migrate();
      write(destination, 'active_view', 'calendar');
      write(destination, 'nightmail_cache.sqlite', 'newer');
      migrate();

      expect(read(destination, 'active_view'), 'calendar');
      expect(read(destination, 'nightmail_cache.sqlite'), 'newer');
    });

    test('is harmless on an install that has none of the old locations', () {
      containerSupport.deleteSync();
      containerDocuments.deleteSync();
      librarySupport.deleteSync();
      userDocuments.deleteSync();

      migrate();

      expect(destination.existsSync(), isTrue);
      expect(destination.listSync(), isEmpty);
    });
  });
}
