import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/sync/removal_tombstone_store.dart';

void main() {
  group('RemovalTombstoneStore', () {
    test('reports a recorded id as active for its account', () {
      final store = RemovalTombstoneStore();
      store.record('acc-1', 'id-1');

      expect(store.activeIds('acc-1'), {'id-1'});
    });

    test('scopes ids by account (IMAP UIDs collide across accounts)', () {
      final store = RemovalTombstoneStore();
      store.record('acc-1', 'shared-uid');

      expect(store.activeIds('acc-1'), {'shared-uid'});
      expect(store.activeIds('acc-2'), isEmpty);
    });

    test('drops an id once its ttl has elapsed', () {
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final store = RemovalTombstoneStore(
        ttl: const Duration(seconds: 30),
        now: () => clock,
      );
      store.record('acc-1', 'id-1');

      clock = clock.add(const Duration(seconds: 29));
      expect(store.activeIds('acc-1'), {'id-1'}, reason: 'still inside window');

      clock = clock.add(const Duration(seconds: 2)); // now 31s past record
      expect(store.activeIds('acc-1'), isEmpty, reason: 'window expired');
    });

    test('re-recording an id refreshes its expiry', () {
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final store = RemovalTombstoneStore(
        ttl: const Duration(seconds: 30),
        now: () => clock,
      );
      store.record('acc-1', 'id-1');

      clock = clock.add(const Duration(seconds: 20));
      store.record('acc-1', 'id-1'); // refresh
      clock = clock.add(const Duration(seconds: 20)); // 40s from first, 20s from refresh

      expect(store.activeIds('acc-1'), {'id-1'});
    });
  });
}
