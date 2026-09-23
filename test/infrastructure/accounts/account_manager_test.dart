import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/config/oauth_client_id_storage.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/accounts/account_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'account_manager_test.mocks.dart';

class MockPathProviderPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '.';
}

@GenerateMocks([AccountStorage, FlutterSecureStorage])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = MockPathProviderPlatform();
  late AccountManager accountManager;
  late MockAccountStorage mockAccountStorage;
  late MockFlutterSecureStorage mockSecureStorage;

  setUp(() {
    mockAccountStorage = MockAccountStorage();
    mockSecureStorage = MockFlutterSecureStorage();
    accountManager = AccountManager(
      accountStorage: mockAccountStorage,
      secureStorage: mockSecureStorage,
      clientIdStorage: OAuthClientIdStorage(mockSecureStorage),
    );
  });

  /// A shared Microsoft mailbox holds no credentials of its own: its token
  /// lives under the signed-in owner's key (`_microsoftAuthConfig` resolves
  /// `parentAccountId` for exactly that). Asking the shared account directly
  /// reads no token at all — which reports "permission needed" forever, and
  /// then re-authenticates the wrong mailbox when the user agrees.
  group('out-of-office write access resolves the credential owner', () {
    const owner = MicrosoftAccount(
      id: 'owner-1',
      displayName: 'Owner',
      emailAddress: 'owner@contoso.com',
      tenantId: 'common',
    );
    const shared = MicrosoftAccount(
      id: 'shared-1',
      displayName: 'Support',
      emailAddress: 'support@contoso.com',
      tenantId: 'common',
      parentAccountId: 'owner-1',
    );

    String tokenJson(String scope) => jsonEncode({
          'access_token': 'a',
          'expires_at':
              DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
          'refresh_token': 'r',
          'token_type': 'Bearer',
          'scope': scope,
        });

    Future<void> signIn(String ownerScope) async {
      when(mockAccountStorage.loadAccounts())
          .thenAnswer((_) async => [owner, shared]);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      when(mockSecureStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);
      when(mockSecureStorage.read(key: 'token_owner-1'))
          .thenAnswer((_) async => tokenJson(ownerScope));
      // The shared mailbox's own key holds nothing — that is the whole point.
      when(mockSecureStorage.read(key: 'token_shared-1'))
          .thenAnswer((_) async => null);
      await accountManager.initialize();
    }

    test('reads the owner\'s grant, not the shared mailbox\'s empty key',
        () async {
      await signIn('Mail.ReadWrite MailboxSettings.ReadWrite');
      expect(await accountManager.hasOutOfOfficeWriteAccess('shared-1'), isTrue);
    });

    test('and still reports a missing grant as missing', () async {
      await signIn('Mail.ReadWrite MailboxSettings.Read');
      expect(
          await accountManager.hasOutOfOfficeWriteAccess('shared-1'), isFalse);
      expect(await accountManager.hasOutOfOfficeWriteAccess('owner-1'), isFalse);
    });
  });

  /// The automatic post-sign-in profile prefill must never touch an account
  /// that has no profile of its own to fetch: IMAP has no directory API, and
  /// a shared mailbox's token is the owner's — `/me` there would write the
  /// owner's name and phone onto the shared account.
  group('prefillOwnProfileFields skips accounts without an own profile', () {
    const owner = MicrosoftAccount(
      id: 'owner-1',
      displayName: 'Owner',
      emailAddress: 'owner@contoso.com',
      tenantId: 'common',
    );
    const shared = MicrosoftAccount(
      id: 'shared-1',
      displayName: 'Support',
      emailAddress: 'support@contoso.com',
      tenantId: 'common',
      parentAccountId: 'owner-1',
    );
    const imap = ImapAccount(
      id: 'imap-1',
      displayName: 'IMAP',
      emailAddress: 'me@example.com',
      host: 'imap.example.com',
      port: 993,
      useSsl: true,
      smtpHost: 'smtp.example.com',
      smtpPort: 587,
      smtpUseSsl: false,
    );

    setUp(() async {
      when(mockAccountStorage.loadAccounts())
          .thenAnswer((_) async => [owner, shared, imap]);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      when(mockAccountStorage.saveAccounts(any)).thenAnswer((_) async {});
      when(mockAccountStorage.saveActiveIndex(any)).thenAnswer((_) async {});
      when(mockSecureStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);
      await accountManager.initialize();
      clearInteractions(mockAccountStorage);
    });

    test('IMAP account: nothing fetched, nothing saved', () async {
      expect(await accountManager.prefillOwnProfileFields('imap-1'), isFalse);
      verifyNever(mockAccountStorage.saveAccounts(any));
    });

    test('shared mailbox: nothing fetched, nothing saved', () async {
      expect(await accountManager.prefillOwnProfileFields('shared-1'), isFalse);
      verifyNever(mockAccountStorage.saveAccounts(any));
    });

    test('unknown account id: nothing saved', () async {
      expect(await accountManager.prefillOwnProfileFields('nope'), isFalse);
      verifyNever(mockAccountStorage.saveAccounts(any));
    });
  });

  group('AccountManager Sorting', () {
    test('should sort accounts alphabetically by display name on initialize', () async {
      final accounts = [
        const GmailAccount(id: '1', displayName: 'Zebra', emailAddress: 'z@test.com'),
        const GmailAccount(id: '2', displayName: 'Alpha', emailAddress: 'a@test.com'),
      ];

      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => accounts);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      when(mockSecureStorage.read(key: anyNamed('key'))).thenAnswer((_) async => null);

      await accountManager.initialize();

      expect(accountManager.accounts[0].displayName, 'Alpha');
      expect(accountManager.accounts[1].displayName, 'Zebra');
      // Original active index 0 was 'Zebra', which is now at index 1
      expect(accountManager.activeIndex, 1);
    });

    test('should sort by email if display name is empty', () async {
      final accounts = [
        const GmailAccount(id: '1', displayName: '', emailAddress: 'z@test.com'),
        const GmailAccount(id: '2', displayName: '', emailAddress: 'a@test.com'),
      ];

      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => accounts);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      when(mockSecureStorage.read(key: anyNamed('key'))).thenAnswer((_) async => null);

      await accountManager.initialize();

      expect(accountManager.accounts[0].emailAddress, 'a@test.com');
      expect(accountManager.accounts[1].emailAddress, 'z@test.com');
    });

    test('addAccount should maintain alphabetical order', () async {
       final accounts = [
        const GmailAccount(id: '1', displayName: 'Zebra', emailAddress: 'z@test.com'),
      ];

      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => accounts);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      when(mockAccountStorage.saveAccounts(any)).thenAnswer((_) async {});
      when(mockAccountStorage.saveActiveIndex(any)).thenAnswer((_) async {});
      when(mockSecureStorage.read(key: anyNamed('key'))).thenAnswer((_) async => null);

      await accountManager.initialize();

      final newAccount = const GmailAccount(id: '2', displayName: 'Alpha', emailAddress: 'a@test.com');
      await accountManager.addAccount(newAccount);

      expect(accountManager.accounts[0].displayName, 'Alpha');
      expect(accountManager.accounts[1].displayName, 'Zebra');
      // Alpha is active, so index should be 0
      expect(accountManager.activeIndex, 0);
    });

    test('updateAccount should maintain alphabetical order', () async {
      final accounts = [
        const GmailAccount(id: '1', displayName: 'Beta', emailAddress: 'b@test.com'),
        const GmailAccount(id: '2', displayName: 'Zebra', emailAddress: 'z@test.com'),
      ];

      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => accounts);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0); // Beta
      when(mockAccountStorage.saveAccounts(any)).thenAnswer((_) async {});
      when(mockAccountStorage.saveActiveIndex(any)).thenAnswer((_) async {});
      when(mockSecureStorage.read(key: anyNamed('key'))).thenAnswer((_) async => null);

      await accountManager.initialize();

      final updatedAccount = const GmailAccount(id: '2', displayName: 'Alpha', emailAddress: 'a@test.com');
      await accountManager.updateAccount(updatedAccount);

      expect(accountManager.accounts[0].displayName, 'Alpha');
      expect(accountManager.accounts[1].displayName, 'Beta');
      // Beta was active, now it's at index 1
      expect(accountManager.activeIndex, 1);
    });

    test('removeAccount should maintain alphabetical order of remaining accounts', () async {
      final accounts = [
        const ImapAccount(
          id: '1',
          displayName: 'Alpha',
          emailAddress: 'a@test.com',
          host: 'imap.test.com',
          port: 993,
          useSsl: true,
          smtpHost: 'smtp.test.com',
          smtpPort: 587,
          smtpUseSsl: false,
        ),
        const ImapAccount(
          id: '2',
          displayName: 'Beta',
          emailAddress: 'b@test.com',
          host: 'imap.test.com',
          port: 993,
          useSsl: true,
          smtpHost: 'smtp.test.com',
          smtpPort: 587,
          smtpUseSsl: false,
        ),
        const ImapAccount(
          id: '3',
          displayName: 'Zebra',
          emailAddress: 'z@test.com',
          host: 'imap.test.com',
          port: 993,
          useSsl: true,
          smtpHost: 'smtp.test.com',
          smtpPort: 587,
          smtpUseSsl: false,
        ),
      ];

      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => accounts);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 2); // Zebra
      when(mockAccountStorage.saveAccounts(any)).thenAnswer((_) async {});
      when(mockAccountStorage.saveActiveIndex(any)).thenAnswer((_) async {});
      when(mockSecureStorage.read(key: anyNamed('key')))
          .thenAnswer((_) async => null);
      when(mockSecureStorage.delete(key: anyNamed('key')))
          .thenAnswer((_) async {});

      await accountManager.initialize();

      await accountManager.removeAccount('2'); // Remove Beta

      expect(accountManager.accounts.length, 2);
      expect(accountManager.accounts[0].displayName, 'Alpha');
      expect(accountManager.accounts[1].displayName, 'Zebra');
      // Zebra was at index 2, now it should be at index 1
      expect(accountManager.activeIndex, 1);
      expect(accountManager.activeAccount!.displayName, 'Zebra');
    });
  });

  // ---------------------------------------------------------------------------
  // contactsDatasource lifecycle
  // ---------------------------------------------------------------------------

  void stubStorageEmpty() {
    when(mockSecureStorage.read(key: anyNamed('key')))
        .thenAnswer((_) async => null);
  }

  void stubSave() {
    when(mockAccountStorage.saveAccounts(any)).thenAnswer((_) async {});
    when(mockAccountStorage.saveActiveIndex(any)).thenAnswer((_) async {});
  }

  group('contactsDatasource lifecycle', () {
    test('is non-null after a Gmail account is added', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => []);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
      stubSave();

      await accountManager.initialize();
      await accountManager.addAccount(
          const GmailAccount(id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'));

      expect(accountManager.contactsDatasource, isNotNull);
    });

    test('is null for a Microsoft account', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => []);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
      stubSave();

      await accountManager.initialize();
      await accountManager.addAccount(const MicrosoftAccount(
          id: '1', displayName: 'Bob', emailAddress: 'b@corp.com', tenantId: 'tid'));

      expect(accountManager.contactsDatasource, isNull);
    });

    test('is cleared when the last account is removed', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const GmailAccount(id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'),
          ]);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
      stubSave();
      when(mockSecureStorage.delete(key: anyNamed('key')))
          .thenAnswer((_) async {});

      await accountManager.initialize();
      expect(accountManager.contactsDatasource, isNotNull);

      await accountManager.removeAccount('1');
      expect(accountManager.contactsDatasource, isNull);
    });
  });

  group('accountById', () {
    setUp(() {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const GmailAccount(
                id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'),
            const MicrosoftAccount(
                id: '2',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
          ]);
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
    });

    test('finds a configured account regardless of which is active', () async {
      await accountManager.initialize();

      expect(accountManager.accountById('2')?.emailAddress, 'b@corp.com');
      expect(accountManager.activeAccount?.id, isNot('2'));
    });

    test('returns null for an unknown id or a null id', () async {
      await accountManager.initialize();

      expect(accountManager.accountById('nope'), isNull);
      expect(accountManager.accountById(null), isNull);
    });
  });

  group('reauthenticateOAuthAccount', () {
    setUp(() {
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
    });

    test('throws for an unknown account id', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const GmailAccount(
                id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'),
          ]);
      await accountManager.initialize();

      expect(
        () => accountManager.reauthenticateOAuthAccount('missing'),
        throwsA(isA<StateError>()),
      );
    });

    test('throws for an IMAP account, which has no OAuth flow', () async {
      // IMAP re-authentication is a stored password, re-entered through the
      // Settings edit fields — Settings must not offer the browser flow for it.
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const ImapAccount(
              id: '1',
              displayName: 'Mail',
              emailAddress: 'me@example.com',
              host: 'imap.example.com',
              port: 993,
              useSsl: true,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              smtpUseSsl: true,
            ),
          ]);
      await accountManager.initialize();

      expect(
        () => accountManager.reauthenticateOAuthAccount('1'),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Shared mailboxes (MicrosoftAccount.parentAccountId)
  // ---------------------------------------------------------------------------

  group('addSharedMailbox', () {
    setUp(() {
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
      stubSave();
    });

    test('throws when the parent account is not Microsoft', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const GmailAccount(
                id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'),
          ]);
      await accountManager.initialize();

      expect(
        () => accountManager.addSharedMailbox(
          parentAccountId: '1',
          email: 'sales@corp.com',
          displayName: 'Sales',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('adds a MicrosoftAccount riding on the parent and makes it active',
        () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid-1'),
          ]);
      await accountManager.initialize();

      final added = await accountManager.addSharedMailbox(
        parentAccountId: '1',
        email: 'sales@corp.com',
        displayName: 'Sales Team',
      );

      final shared = added as MicrosoftAccount;
      expect(shared.parentAccountId, '1');
      expect(shared.isSharedMailbox, isTrue);
      expect(shared.emailAddress, 'sales@corp.com');
      // Tenant is inherited from the parent — a shared mailbox has no OAuth
      // flow of its own to have discovered one independently.
      expect(shared.tenantId, 'tid-1');
      expect(accountManager.activeAccount?.id, shared.id);
      expect(accountManager.accounts.map((a) => a.id), containsAll(['1', shared.id]));
    });
  });

  group('resolveSharedMailboxCandidate', () {
    setUp(() {
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
    });

    test('returns null when the parent id is not a Microsoft account',
        () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const GmailAccount(
                id: '1', displayName: 'Alice', emailAddress: 'a@gmail.com'),
          ]);
      await accountManager.initialize();

      final result = await accountManager
          .resolveSharedMailboxCandidate('1', 'sales@corp.com');

      expect(result, isNull);
    });

    test(
        'reports needsReauth without reaching the directory when the stored '
        'token predates the .Shared scopes', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
          ]);
      await accountManager.initialize();

      // A token saved before Mail.Read.Shared was added to the requested
      // scopes — the parent can read its own mail but not a shared mailbox.
      when(mockSecureStorage.read(key: 'token_1')).thenAnswer((_) async => jsonEncode({
            'access_token': 'tok',
            'expires_at':
                DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
            'refresh_token': 'refresh',
            'token_type': 'Bearer',
            'scope': 'openid profile https://graph.microsoft.com/Mail.Read',
          }));

      // No Dio/network mocking exists anywhere in this file — if this reached
      // the directory lookup or the probe, the underlying real Dio() would
      // either hang or throw against this sandbox's lack of network access.
      // Completing with the expected result proves the scope check runs
      // first and short-circuits both network calls.
      final result = await accountManager
          .resolveSharedMailboxCandidate('1', 'sales@corp.com');

      expect(result, isNotNull);
      expect(result!.needsReauth, isTrue);
      expect(result.hasAccess, isFalse);
    });
  });

  group('shared mailbox accounts', () {
    setUp(() {
      when(mockAccountStorage.loadActiveIndex()).thenAnswer((_) async => 0);
      stubStorageEmpty();
      stubSave();
      when(mockSecureStorage.delete(key: anyNamed('key')))
          .thenAnswer((_) async {});
    });

    test('removing the parent cascades to its shared mailboxes', () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
            const MicrosoftAccount(
                id: '2',
                displayName: 'Sales',
                emailAddress: 'sales@corp.com',
                tenantId: 'tid',
                parentAccountId: '1'),
          ]);
      await accountManager.initialize();

      await accountManager.removeAccount('1');

      expect(accountManager.accounts, isEmpty);
    });

    test("removing a shared mailbox does not clear the parent's token",
        () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
            const MicrosoftAccount(
                id: '2',
                displayName: 'Sales',
                emailAddress: 'sales@corp.com',
                tenantId: 'tid',
                parentAccountId: '1'),
          ]);
      await accountManager.initialize();

      await accountManager.removeAccount('2');

      verifyNever(mockSecureStorage.delete(key: 'token_1'));
      expect(accountManager.accounts.map((a) => a.id), ['1']);
    });

    test(
        "getUnauthenticatedAccountIds follows the parent's credential status",
        () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
            const MicrosoftAccount(
                id: '2',
                displayName: 'Sales',
                emailAddress: 'sales@corp.com',
                tenantId: 'tid',
                parentAccountId: '1'),
          ]);
      await accountManager.initialize();
      // Parent '1' has no stored token (stubStorageEmpty) — the shared
      // mailbox '2' never has one of its own either way.

      final unauth = await accountManager.getUnauthenticatedAccountIds();

      expect(unauth, containsAll(['1', '2']));
    });

    test(
        'getUnauthenticatedAccountIds treats the shared mailbox as '
        "authenticated once the parent's token is valid", () async {
      when(mockAccountStorage.loadAccounts()).thenAnswer((_) async => [
            const MicrosoftAccount(
                id: '1',
                displayName: 'Bob',
                emailAddress: 'b@corp.com',
                tenantId: 'tid'),
            const MicrosoftAccount(
                id: '2',
                displayName: 'Sales',
                emailAddress: 'sales@corp.com',
                tenantId: 'tid',
                parentAccountId: '1'),
          ]);
      await accountManager.initialize();

      when(mockSecureStorage.read(key: 'token_1')).thenAnswer((_) async => jsonEncode({
            'access_token': 'tok',
            'expires_at':
                DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
            'refresh_token': 'refresh',
          }));

      final unauth = await accountManager.getUnauthenticatedAccountIds();

      expect(unauth, isEmpty);
    });
  });
}
