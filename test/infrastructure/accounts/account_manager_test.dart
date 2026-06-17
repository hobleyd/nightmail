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
}
