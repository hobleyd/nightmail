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
}
