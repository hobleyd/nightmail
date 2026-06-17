import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/repositories/system_contacts_repository_impl.dart';

void main() {
  group('SystemContactsRepositoryImpl', () {
    // These tests run on the host platform (Windows/Linux in CI). The macOS
    // native channel is not registered in that environment, so any call that
    // reaches it would throw MissingPluginException. Passing here confirms
    // that the isMacOS guard is in place and effective.

    test('search returns empty list without invoking the native channel', () async {
      if (Platform.isMacOS) {
        // On a real macOS machine the channel exists; skip to avoid needing
        // Contacts permission in CI.
        return;
      }
      final repo = SystemContactsRepositoryImpl();
      final results = await repo.search('anything');
      expect(results, isEmpty);
    });

    test('warmUp completes without error on non-macOS', () async {
      if (Platform.isMacOS) return;
      final repo = SystemContactsRepositoryImpl();
      await expectLater(repo.warmUp(), completes);
    });

    test('search returns empty list for empty query on non-macOS', () async {
      if (Platform.isMacOS) return;
      final repo = SystemContactsRepositoryImpl();
      expect(await repo.search(''), isEmpty);
    });
  });
}
