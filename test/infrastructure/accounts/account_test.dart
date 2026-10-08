import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';

void main() {
  group('MicrosoftAccount.parentAccountId', () {
    test('isSharedMailbox is false when parentAccountId is unset', () {
      const account = MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Alice',
        emailAddress: 'alice@corp.com',
        tenantId: 'tid',
      );

      expect(account.parentAccountId, isNull);
      expect(account.isSharedMailbox, isFalse);
    });

    test('isSharedMailbox is true once parentAccountId is set', () {
      const account = MicrosoftAccount(
        id: 'acct-shared',
        displayName: 'Sales Team',
        emailAddress: 'sales@corp.com',
        tenantId: 'tid',
        parentAccountId: 'acct-1',
      );

      expect(account.parentAccountId, 'acct-1');
      expect(account.isSharedMailbox, isTrue);
    });

    test('toJson omits parentAccountId when unset', () {
      const account = MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Alice',
        emailAddress: 'alice@corp.com',
        tenantId: 'tid',
      );

      expect(account.toJson().containsKey('parentAccountId'), isFalse);
    });

    test('toJson/fromJson round-trips parentAccountId', () {
      const account = MicrosoftAccount(
        id: 'acct-shared',
        displayName: 'Sales Team',
        emailAddress: 'sales@corp.com',
        tenantId: 'tid',
        parentAccountId: 'acct-1',
      );

      final restored = Account.fromJson(account.toJson());

      expect(restored, isA<MicrosoftAccount>());
      expect((restored as MicrosoftAccount).parentAccountId, 'acct-1');
      expect(restored.isSharedMailbox, isTrue);
      expect(restored, account);
    });

    test('fromJson defaults parentAccountId to null when absent', () {
      final restored = Account.fromJson(const {
        'type': 'microsoft',
        'id': 'acct-1',
        'displayName': 'Alice',
        'emailAddress': 'alice@corp.com',
        'tenantId': 'tid',
      });

      expect(restored, isA<MicrosoftAccount>());
      expect((restored as MicrosoftAccount).parentAccountId, isNull);
    });

    test('copyWith preserves parentAccountId — there is no way to clear it',
        () {
      const account = MicrosoftAccount(
        id: 'acct-shared',
        displayName: 'Sales Team',
        emailAddress: 'sales@corp.com',
        tenantId: 'tid',
        parentAccountId: 'acct-1',
      );

      final renamed = account.copyWith(displayName: 'Sales');

      expect(renamed.displayName, 'Sales');
      expect(renamed.parentAccountId, 'acct-1');
    });

    test('a shared mailbox is not equal to the same account without a parent',
        () {
      const shared = MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Alice',
        emailAddress: 'alice@corp.com',
        tenantId: 'tid',
        parentAccountId: 'acct-0',
      );
      const direct = MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Alice',
        emailAddress: 'alice@corp.com',
        tenantId: 'tid',
      );

      expect(shared, isNot(direct));
    });
  });

  /// The addresses a mailbox answers for, as the provider lists them, are what
  /// a reply-all strips from its recipients. An account that knows only its
  /// primary — or, before 1.37.4 learned it on add, not even that — left the
  /// user in their own Reply All.
  group('Account.aliases', () {
    const gmail = GmailAccount(
      id: 'g',
      displayName: 'HTW',
      emailAddress: 'me@htw.com.au',
    );

    test('allAddresses is the primary and every alias, trimmed, lower-cased',
        () {
      final account = gmail.copyWith(
          aliases: const [' Alias@HTW.com.au ', '', 'other@htw.com.au']);

      expect(account.allAddresses,
          {'me@htw.com.au', 'alias@htw.com.au', 'other@htw.com.au'});
    });

    test('allAddresses is empty, not {""}, with no address on record', () {
      expect(gmail.copyWith(emailAddress: '').allAddresses, isEmpty);
    });

    test('withMailboxAddresses adopts the primary for an account recorded '
        'without one, and keeps the rest as aliases', () {
      final learned = gmail
          .copyWith(emailAddress: '')
          .withMailboxAddresses(const ['me@htw.com.au', 'alias@htw.com.au']);

      expect(learned.emailAddress, 'me@htw.com.au');
      expect(learned.aliases, ['alias@htw.com.au']);
    });

    test('withMailboxAddresses keeps a recorded address the provider does not '
        'list — typed into Settings — and makes every listed one an alias',
        () {
      final learned = gmail
          .copyWith(emailAddress: 'typed@htw.com.au')
          .withMailboxAddresses(const ['me@htw.com.au', 'alias@htw.com.au']);

      expect(learned.emailAddress, 'typed@htw.com.au');
      expect(learned.aliases, ['me@htw.com.au', 'alias@htw.com.au']);
    });

    test('withMailboxAddresses leaves the primary out of the aliases, '
        'whatever its case, and drops duplicates', () {
      final learned = gmail.withMailboxAddresses(
          const ['ME@htw.com.au', 'alias@htw.com.au', 'Alias@htw.com.au']);

      expect(learned.emailAddress, 'me@htw.com.au');
      expect(learned.aliases, ['alias@htw.com.au']);
    });

    test('a provider listing only the primary records an empty alias list: '
        'asked and answered, not unknown', () {
      expect(gmail.withMailboxAddresses(const ['me@htw.com.au']).aliases,
          isEmpty);
    });

    test('an empty answer is "could not tell" and changes nothing', () {
      expect(gmail.withMailboxAddresses(const []), same(gmail));
      expect(gmail.withMailboxAddresses(const ['', ' ']), same(gmail));
      expect(gmail.aliases, isNull);
    });

    test('aliases round-trip JSON for every account type; absent means never '
        'asked', () {
      const imap = ImapAccount(
        id: 'i',
        displayName: 'Mail',
        emailAddress: 'me@example.com',
        host: 'imap.example.com',
        port: 993,
        useSsl: true,
        smtpHost: 'smtp.example.com',
        smtpPort: 587,
        smtpUseSsl: false,
      );
      const microsoft = MicrosoftAccount(
        id: 'm',
        displayName: 'Work',
        emailAddress: 'me@contoso.com',
        tenantId: 'tid',
      );

      for (final account in [gmail, imap, microsoft]) {
        expect(account.toJson().containsKey('aliases'), isFalse);
        expect(Account.fromJson(account.toJson()).aliases, isNull);

        final known = account.copyWith(aliases: const ['alias@example.com']);
        final restored = Account.fromJson(known.toJson());
        expect(restored.aliases, ['alias@example.com']);
        expect(restored, known);
        expect(restored, isNot(account),
            reason: 'learned aliases must count in equality, or the backfill '
                'would never see a change to save');

        final asked = account.copyWith(aliases: const []);
        expect(Account.fromJson(asked.toJson()).aliases, isEmpty);
      }
    });
  });
}
