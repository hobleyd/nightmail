// Drift round-trip tests for the address-book cache. The real in-memory
// database is the unit under test — the SQL ranking and LIKE escaping are the
// behaviour worth covering, and neither survives being mocked.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/contact_cache_local_datasource.dart';
import 'package:nightmail/data/datasources/local/contact_cache_local_datasource_impl.dart';
import 'package:nightmail/domain/entities/cached_contact.dart';

void main() {
  late AppDatabase db;
  late ContactCacheLocalDatasource ds;

  const accountId = 'acc1';

  CachedContact contact(
    String address, {
    String name = '',
    ContactSource source = ContactSource.directory,
  }) =>
      CachedContact(address: address, name: name, source: source);

  Future<void> seed(
    List<CachedContact> contacts, {
    String account = accountId,
  }) =>
      ds.replaceForAccount(
        accountId: account,
        contacts: contacts,
        status: 'ok',
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ds = ContactCacheLocalDatasourceImpl(database: db);
  });

  tearDown(() => db.close());

  group('replaceForAccount', () {
    test('round-trips contacts and records the sync outcome', () async {
      await seed([contact('alice@corp.com', name: 'Alice Anderson')]);

      final results = await ds.search(accountId: accountId, query: 'alice');
      expect(results.single.address, 'alice@corp.com');
      expect(results.single.name, 'Alice Anderson');
      expect(results.single.source, ContactSource.directory);

      final status = await ds.syncStatus(accountId);
      expect(status!.status, 'ok');
      expect(status.isClean, isTrue);
      expect(status.contactCount, 1);
      expect(status.detail, isNull);
    });

    test('replaces the previous slice rather than merging into it', () async {
      await seed([contact('old@corp.com', name: 'Old Entry')]);
      await seed([contact('new@corp.com', name: 'New Entry')]);

      expect(await ds.search(accountId: accountId, query: 'old'), isEmpty);
      expect(
        (await ds.search(accountId: accountId, query: 'new')).single.address,
        'new@corp.com',
      );
    });

    test('leaves other accounts untouched', () async {
      await seed([contact('a@corp.com', name: 'Alpha')]);
      await seed([contact('b@corp.com', name: 'Beta')], account: 'acc2');
      await seed([contact('c@corp.com', name: 'Gamma')]);

      expect(
        (await ds.search(accountId: 'acc2', query: 'b@')).single.address,
        'b@corp.com',
      );
      expect(
        (await ds.search(accountId: accountId, query: 'c@')).single.address,
        'c@corp.com',
      );
    });

    test('records a partial sync with its detail', () async {
      await ds.replaceForAccount(
        accountId: accountId,
        contacts: [contact('a@corp.com')],
        status: 'partial',
        detail: 'directory: HTTP 403',
      );

      final status = await ds.syncStatus(accountId);
      expect(status!.isClean, isFalse);
      expect(status.detail, 'directory: HTTP 403');
    });
  });

  group('search', () {
    test('matches on both name and address', () async {
      await seed([
        contact('zzz@corp.com', name: 'Alice Anderson'),
        contact('alice@other.com', name: 'Someone Else'),
      ]);

      expect(
        (await ds.search(accountId: accountId, query: 'alice'))
            .map((c) => c.address)
            .toSet(),
        {'zzz@corp.com', 'alice@other.com'},
      );
    });

    test('ranks a name prefix above a mid-string match', () async {
      await seed([
        // 'ash' appears inside 'Natasha' but starts neither the name nor a
        // word within it.
        contact('a@corp.com', name: 'Natasha Grey'),
        contact('b@corp.com', name: 'Ash Kumar'),
      ]);

      final results = await ds.search(accountId: accountId, query: 'ash');

      expect(results.first.address, 'b@corp.com');
      expect(results.last.address, 'a@corp.com');
    });

    test('ranks an address prefix above a mid-string match', () async {
      await seed([
        contact('natasha@corp.com', name: ''),
        contact('ash@corp.com', name: ''),
      ]);

      final results = await ds.search(accountId: accountId, query: 'ash');

      expect(results.first.address, 'ash@corp.com');
    });

    test('ranks a word inside the name above a mid-word match', () async {
      await seed([
        contact('a@corp.com', name: 'Nathob Kim'),
        contact('b@corp.com', name: 'Zara Hobley'),
      ]);

      final results = await ds.search(accountId: accountId, query: 'hob');

      expect(results.first.address, 'b@corp.com');
    });

    test('prefers named entries over bare addresses at the same rank',
        () async {
      await seed([
        contact('corp1@corp.com', name: ''),
        contact('corp2@corp.com', name: 'Corp Person'),
      ]);

      final results = await ds.search(accountId: accountId, query: 'corp');

      expect(results.first.name, 'Corp Person');
    });

    test('includes the OS address book alongside the account', () async {
      await seed([contact('work@corp.com', name: 'Work Person')]);
      await seed(
        [
          CachedContact(
            address: 'personal@home.com',
            name: 'Personal Person',
            source: ContactSource.system,
          )
        ],
        account: systemContactsAccountId,
      );

      final results = await ds.search(accountId: accountId, query: 'person');

      expect(
        results.map((c) => c.address).toSet(),
        {'work@corp.com', 'personal@home.com'},
      );
    });

    test('excludes contacts belonging to a different account', () async {
      await seed([contact('mine@corp.com', name: 'Mine')]);
      await seed([contact('theirs@corp.com', name: 'Theirs')],
          account: 'acc2');

      final results = await ds.search(accountId: accountId, query: 'corp');

      expect(results.map((c) => c.address), ['mine@corp.com']);
    });

    test('honours the limit', () async {
      await seed([
        for (var i = 0; i < 20; i++)
          contact('user$i@corp.com', name: 'User $i'),
      ]);

      expect(
        (await ds.search(accountId: accountId, query: 'user', limit: 5)).length,
        5,
      );
    });

    test('returns nothing for an empty query', () async {
      await seed([contact('a@corp.com', name: 'Alice')]);

      expect(await ds.search(accountId: accountId, query: ''), isEmpty);
    });

    test('treats LIKE wildcards in the query as literal characters', () async {
      // A bare '%' would otherwise match every row, and '_' any single
      // character — both are legal in an address local part.
      await seed([
        contact('a_b@corp.com', name: 'Underscore Local'),
        contact('axb@corp.com', name: 'Other Local'),
        contact('plain@corp.com', name: 'Plain'),
      ]);

      expect(
        (await ds.search(accountId: accountId, query: '%')).map((c) => c.address),
        isEmpty,
      );
      expect(
        (await ds.search(accountId: accountId, query: 'a_b'))
            .map((c) => c.address),
        ['a_b@corp.com'],
      );
    });

    test('treats a backslash in the query as a literal character', () async {
      await seed([contact('plain@corp.com', name: 'Plain')]);

      expect(
        await ds.search(accountId: accountId, query: r'\'),
        isEmpty,
      );
    });
  });

  group('markSyncFailed', () {
    test('records the failure without discarding cached contacts', () async {
      await seed([contact('alice@corp.com', name: 'Alice')]);

      await ds.markSyncFailed(accountId: accountId, detail: 'network down');

      final status = await ds.syncStatus(accountId);
      expect(status!.status, 'error');
      expect(status.detail, 'network down');
      // The previous, good cache survives so the typeahead keeps working.
      expect(status.contactCount, 1);
      expect(
        (await ds.search(accountId: accountId, query: 'alice')).single.address,
        'alice@corp.com',
      );
    });

    test('works for an account that has never synced', () async {
      await ds.markSyncFailed(accountId: accountId, detail: 'no datasource');

      final status = await ds.syncStatus(accountId);
      expect(status!.status, 'error');
      expect(status.contactCount, 0);
    });
  });

  group('bookkeeping', () {
    test('syncStatus is null until a sync is recorded', () async {
      expect(await ds.syncStatus(accountId), isNull);
    });

    test('hasContacts reflects whether rows exist', () async {
      expect(await ds.hasContacts(accountId), isFalse);

      await seed([contact('a@corp.com')]);
      expect(await ds.hasContacts(accountId), isTrue);

      await seed(const []);
      expect(await ds.hasContacts(accountId), isFalse);
    });

    test('cachedAccountIds lists every synced slice', () async {
      await seed([contact('a@corp.com')]);
      await seed([contact('b@corp.com')], account: 'acc2');

      expect(
        (await ds.cachedAccountIds()).toSet(),
        {accountId, 'acc2'},
      );
    });

    test('clearAccount drops both the contacts and the sync state', () async {
      await seed([contact('a@corp.com', name: 'Alpha')]);

      await ds.clearAccount(accountId);

      expect(await ds.search(accountId: accountId, query: 'alpha'), isEmpty);
      expect(await ds.syncStatus(accountId), isNull);
      expect(await ds.cachedAccountIds(), isEmpty);
    });
  });
}
