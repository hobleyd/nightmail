import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/sync/recent_mutation_store.dart';

void main() {
  group('RecentMutationStore', () {
    test('reports a recorded id as active for its account', () {
      final store = RecentMutationStore();
      store.recordRemoval('acc-1', 'id-1');

      expect(store.recentlyRemovedIds('acc-1'), {'id-1'});
    });

    test('scopes ids by account (IMAP UIDs collide across accounts)', () {
      final store = RecentMutationStore();
      store.recordRemoval('acc-1', 'shared-uid');

      expect(store.recentlyRemovedIds('acc-1'), {'shared-uid'});
      expect(store.recentlyRemovedIds('acc-2'), isEmpty);
    });

    test('a read change is not a removal, and vice versa', () {
      final store = RecentMutationStore();
      store.recordReadChange('acc-1', 'read-1', isRead: true);
      store.recordRemoval('acc-1', 'gone-1');

      expect(store.recentReadStates('acc-1'), {'read-1': true});
      expect(store.recentlyRemovedIds('acc-1'), {'gone-1'});
    });

    test('a later read change to the same message replaces the value', () {
      final store = RecentMutationStore();
      store.recordReadChange('acc-1', 'id-1', isRead: true);
      store.recordReadChange('acc-1', 'id-1', isRead: false);

      expect(store.recentReadStates('acc-1'), {'id-1': false});
    });

    test('drops an id once its ttl has elapsed', () {
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final store = RecentMutationStore(
        ttl: const Duration(seconds: 30),
        now: () => clock,
      );
      store.recordRemoval('acc-1', 'id-1');

      clock = clock.add(const Duration(seconds: 29));
      expect(store.recentlyRemovedIds('acc-1'), {'id-1'}, reason: 'still inside window');

      clock = clock.add(const Duration(seconds: 2)); // now 31s past record
      expect(store.recentlyRemovedIds('acc-1'), isEmpty, reason: 'window expired');
    });

    test('re-recording an id refreshes its expiry', () {
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final store = RecentMutationStore(
        ttl: const Duration(seconds: 30),
        now: () => clock,
      );
      store.recordRemoval('acc-1', 'id-1');

      clock = clock.add(const Duration(seconds: 20));
      store.recordRemoval('acc-1', 'id-1'); // refresh
      clock = clock.add(const Duration(seconds: 20)); // 40s from first, 20s from refresh

      expect(store.recentlyRemovedIds('acc-1'), {'id-1'});
    });
  });
}
