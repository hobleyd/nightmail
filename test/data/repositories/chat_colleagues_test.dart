import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/repositories/chat_repository_impl.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

/// The Chat pane offers only colleagues: someone on one of the account's own
/// domains, or in its cached directory (a tenant with several domains). A
/// personal domain makes nobody a colleague.
void main() {
  ChatRepositoryImpl repo(Account account, {Set<String> directory = const {}}) =>
      ChatRepositoryImpl(
        accountManager: _Accounts(account),
        contacts: _Directory(directory),
      );

  final work = MicrosoftAccount(
    id: 'a',
    displayName: 'Work',
    emailAddress: 'me@contoso.com',
    aliases: const ['me@contoso.co.uk'],
    tenantId: 't',
  );

  test('own domains and aliases\' domains are colleagues', () async {
    final found = await repo(work).colleagues('a', [
      'Bob@Contoso.com',
      'ann@contoso.co.uk',
      'eve@fabrikam.com',
    ]);
    expect(found, {'bob@contoso.com', 'ann@contoso.co.uk'});
  });

  test('the cached directory adds the tenant\'s other domains', () async {
    final found = await repo(work, directory: {'kim@contoso-labs.com'})
        .colleagues('a', ['kim@contoso-labs.com', 'eve@fabrikam.com']);
    expect(found, {'kim@contoso-labs.com'});
  });

  test('a personal domain makes nobody a colleague', () async {
    final personal = MicrosoftAccount(
      id: 'p',
      displayName: 'Me',
      emailAddress: 'me@outlook.com',
      tenantId: 'consumers',
    );
    final found = await repo(personal).colleagues('p', ['you@outlook.com']);
    expect(found, isEmpty);
  });
}

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.account);

  final Account account;

  @override
  Account? accountById(String? id) => id == account.id ? account : null;
}

class _Directory extends Fake implements ContactCacheRepository {
  _Directory(this.members);

  final Set<String> members;

  @override
  Future<Set<String>> directoryAddresses({
    required String accountId,
    required Iterable<String> addresses,
  }) async =>
      addresses.where(members.contains).toSet();
}
