import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../../core/config/oauth_client_id_storage.dart';
import '../../data/datasources/remote/caldav_calendar_datasource_impl.dart';
import '../../data/datasources/remote/calendar_remote_datasource.dart';
import '../../data/datasources/remote/email_remote_datasource.dart';
import '../../data/datasources/remote/eventkit_calendar_datasource_impl.dart';
import '../../data/datasources/remote/gmail_contacts_datasource_impl.dart';
import '../../data/datasources/remote/gmail_datasource_impl.dart';
import '../../data/datasources/remote/google_calendar_datasource_impl.dart';
import '../../data/datasources/remote/google_tasks_datasource_impl.dart';
import '../../data/datasources/remote/graph_api_datasource_impl.dart';
import '../../data/datasources/remote/imap_datasource_impl.dart';
import '../../data/datasources/remote/tasks_remote_datasource.dart';
import '../auth/auth_service.dart';
import '../auth/caldav_credential_storage.dart';
import '../auth/gmail_auth_service.dart';
import '../auth/imap_auth_service.dart';
import '../auth/imap_credential_storage.dart';
import '../auth/microsoft_auth_service.dart';
import '../auth/token_storage.dart';
import '../http/gmail_http_client.dart';
import '../http/google_calendar_http_client.dart';
import '../http/google_people_http_client.dart';
import '../http/google_tasks_http_client.dart';
import '../http/graph_http_client.dart';
import 'account.dart';
import 'account_storage.dart';

class AccountManager {
  AccountManager({
    required AccountStorage accountStorage,
    required FlutterSecureStorage secureStorage,
    required OAuthClientIdStorage clientIdStorage,
  })  : _accountStorage = accountStorage,
        _secureStorage = secureStorage,
        _clientIdStorage = clientIdStorage;

  final AccountStorage _accountStorage;
  final FlutterSecureStorage _secureStorage;
  final OAuthClientIdStorage _clientIdStorage;

  // Cached client IDs/secrets loaded (and migrated) in initialize().
  String? _microsoftClientId;
  String? _googleClientId;
  String? _googleClientSecret;

  List<Account> _accounts = [];
  int _activeIndex = 0;

  EmailRemoteDatasource? _emailDatasource;
  CalendarRemoteDatasource? _calendarDatasource;
  TasksRemoteDatasource? _tasksDatasource;
  AuthService? _authService;

  // Fired by AuthInterceptor (the single choke point every Graph/Gmail/
  // Calendar/Tasks/People request passes through) whenever a token refresh
  // fails for an account, so the UI can flag it as needing re-authentication
  // regardless of which call site triggered the failing request.
  final _authFailureController = StreamController<String>.broadcast();
  Stream<String> get authFailures => _authFailureController.stream;

  // Lazily built and cached per Gmail account ID so contact search works for
  // any account regardless of which one is currently active.
  final Map<String, GmailContactsDatasourceImpl> _contactsDatasourceCache = {};

  // Lazily built and cached per Microsoft account ID so directory profile
  // lookups (contact hover card) work for any account, not just the active
  // one. Reuses GraphApiDatasourceImpl since directory lookups hit the same
  // Graph host/auth as email.
  final Map<String, GraphApiDatasourceImpl> _directoryDatasourceCache = {};

  List<Account> get accounts => List.unmodifiable(_accounts);
  bool get hasAccounts => _accounts.isNotEmpty;
  int get activeIndex => _activeIndex;

  Account? get activeAccount =>
      _accounts.isEmpty ? null : _accounts[_activeIndex];

  EmailRemoteDatasource get emailDatasource {
    if (_emailDatasource == null) throw StateError('No active account');
    return _emailDatasource!;
  }

  CalendarRemoteDatasource? get calendarDatasource => _calendarDatasource;
  TasksRemoteDatasource? get tasksDatasource => _tasksDatasource;

  GmailContactsDatasourceImpl? get contactsDatasource {
    final id = activeAccount?.id;
    if (id == null) return null;
    return contactsDatasourceForAccount(id);
  }

  GmailContactsDatasourceImpl? contactsDatasourceForAccount(String accountId) {
    if (_contactsDatasourceCache.containsKey(accountId)) {
      return _contactsDatasourceCache[accountId];
    }
    final account = _accounts.cast<Account?>().firstWhere(
      (a) => a?.id == accountId,
      orElse: () => null,
    );
    if (account is! GmailAccount) return null;
    final tokenStorage = TokenStorage(
      _secureStorage,
      storageKey: 'token_${account.id}',
    );
    final authSvc = GmailAuthService(
      clientId: _googleClientId ?? AppConfig.gmailClientId,
      clientSecret: _googleClientSecret ?? '',
      redirectUri: AppConfig.gmailRedirectUri,
      tokenStorage: tokenStorage,
    );
    final ds = GmailContactsDatasourceImpl(
      client: GooglePeopleHttpClient(
        authService: authSvc,
        onAuthFailure: () => _authFailureController.add(accountId),
      ),
    );
    _contactsDatasourceCache[accountId] = ds;
    return ds;
  }

  GraphApiDatasourceImpl? directoryDatasourceForAccount(String accountId) {
    if (_directoryDatasourceCache.containsKey(accountId)) {
      return _directoryDatasourceCache[accountId];
    }
    final account = _accounts.cast<Account?>().firstWhere(
      (a) => a?.id == accountId,
      orElse: () => null,
    );
    if (account is! MicrosoftAccount) return null;
    final tokenStorage = TokenStorage(
      _secureStorage,
      storageKey: 'token_${account.id}',
    );
    final authSvc = MicrosoftAuthService(
      clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
      tenantId: account.tenantId,
      redirectUri: AppConfig.microsoftRedirectUri,
      tokenStorage: tokenStorage,
    );
    final ds = GraphApiDatasourceImpl(
      client: GraphHttpClient(
        authService: authSvc,
        onAuthFailure: () => _authFailureController.add(accountId),
      ),
    );
    _directoryDatasourceCache[accountId] = ds;
    return ds;
  }

  AuthService get activeAuthService {
    if (_authService == null) throw StateError('No active account');
    return _authService!;
  }

  /// Load persisted accounts and run legacy token migration if needed.
  Future<void> initialize() async {
    await _loadAndMigrateClientIds();
    _accounts = await _accountStorage.loadAccounts();
    if (_accounts.isEmpty) {
      await _migrateLegacyAccount();
      _accounts = await _accountStorage.loadAccounts();
    }
    _activeIndex = await _accountStorage.loadActiveIndex();
    if (_activeIndex >= _accounts.length) _activeIndex = 0;
    _sortAccounts();
    if (_accounts.isNotEmpty) {
      _buildDatasourcesForActiveAccount();
      await _migrateLegacyTokenIfNeeded();
      await _backfillActiveAccountEmailIfNeeded();
    }
  }

  /// One-time migration for the case where accounts were loaded from the legacy
  /// file but the token was stored under the old single-account key
  /// ('nightmail_auth_token') rather than the per-account key ('token_{id}').
  ///
  /// This happens when:
  ///  1. The accounts file survived (keychain writes were failing) so
  ///     _migrateLegacyAccount() was never called.
  ///  2. The token was in the legacy plain file (.nightmail_auth_token) which
  ///     TokenStorage.loadToken() can still pick up via _migrateLegacyFile().
  Future<void> _migrateLegacyTokenIfNeeded() async {
    final account = activeAccount;
    if (account is! MicrosoftAccount) return;
    try {
      final perAccount =
          TokenStorage(_secureStorage, storageKey: 'token_${account.id}');
      if (await perAccount.loadToken() != null) return;

      // Per-account token missing — try the old single-account key.
      final legacy = TokenStorage(_secureStorage);
      final token = await legacy.loadToken();
      if (token == null) return;

      await perAccount.saveToken(token);
      await legacy.clearToken();
    } catch (_) {}
  }

  /// Reload client IDs from storage (picks up values saved by the sign-in
  /// screen after the last initialize() call).
  Future<void> _loadAndMigrateClientIds() async {
    _microsoftClientId = await _clientIdStorage.loadMicrosoftClientId();
    if (_microsoftClientId == null) {
      const compiled = AppConfig.microsoftClientId;
      if (compiled != 'YOUR_CLIENT_ID') {
        await _clientIdStorage.saveMicrosoftClientId(compiled);
        _microsoftClientId = compiled;
      }
    }

    _googleClientId = await _clientIdStorage.loadGoogleClientId();
    if (_googleClientId == null) {
      const compiled = AppConfig.gmailClientId;
      if (compiled != 'YOUR_GOOGLE_CLIENT_ID') {
        await _clientIdStorage.saveGoogleClientId(compiled);
        _googleClientId = compiled;
      }
    }
    _googleClientSecret = await _clientIdStorage.loadGoogleClientSecret();
  }

  /// Add a new account and make it the active account.
  Future<void> addAccount(Account account) async {
    // Reload in case the sign-in screen just saved a new client ID.
    await _loadAndMigrateClientIds();
    _accounts = [..._accounts, account];
    _activeIndex = _accounts.length - 1;
    _sortAccounts();
    await _accountStorage.saveAccounts(_accounts);
    await _accountStorage.saveActiveIndex(_activeIndex);
    _buildDatasourcesForActiveAccount();
  }

  /// Update an existing account.
  Future<void> updateAccount(Account updatedAccount) async {
    final idx = _accounts.indexWhere((a) => a.id == updatedAccount.id);
    if (idx == -1) return;

    final updatedList = List<Account>.from(_accounts);
    updatedList[idx] = updatedAccount;
    _accounts = updatedList;

    _sortAccounts();

    await _accountStorage.saveAccounts(_accounts);
    await _accountStorage.saveActiveIndex(_activeIndex);

    if (activeAccount?.id == updatedAccount.id) {
      _buildDatasourcesForActiveAccount();
    }
  }

  /// Cycle to the next account. Returns the newly active account.
  Future<Account> cycleToNextAccount() async {
    if (_accounts.length < 2) throw StateError('Need at least 2 accounts to cycle');
    _activeIndex = (_activeIndex + 1) % _accounts.length;
    await _accountStorage.saveActiveIndex(_activeIndex);
    _buildDatasourcesForActiveAccount();
    return _accounts[_activeIndex];
  }

  /// Switch to a specific account by index.
  Future<void> switchToAccount(int index) async {
    if (index < 0 || index >= _accounts.length) {
      throw RangeError.index(index, _accounts);
    }
    _activeIndex = index;
    await _accountStorage.saveActiveIndex(_activeIndex);
    _buildDatasourcesForActiveAccount();
  }

  /// Remove account by ID. Adjusts active index if needed.
  Future<void> removeAccount(String accountId) async {
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx == -1) return;

    await _clearCredentials(_accounts[idx]);
    _contactsDatasourceCache.remove(accountId);
    _directoryDatasourceCache.remove(accountId);

    final updated = [..._accounts]..removeAt(idx);
    _accounts = updated;
    if (_accounts.isEmpty) {
      _activeIndex = 0;
      _emailDatasource = null;
      _calendarDatasource = null;
      _contactsDatasourceCache.clear();
      _directoryDatasourceCache.clear();
      _authService = null;
    } else {
      _activeIndex = _activeIndex.clamp(0, _accounts.length - 1);
      _sortAccounts();
      _buildDatasourcesForActiveAccount();
    }

    await _accountStorage.saveAccounts(_accounts);
    await _accountStorage.saveActiveIndex(_activeIndex);
  }

  /// Returns the set of account IDs that have no stored credentials.
  Future<Set<String>> getUnauthenticatedAccountIds() async {
    final result = <String>{};
    for (final account in _accounts) {
      if (!await _hasCredentials(account)) {
        result.add(account.id);
      }
    }
    return result;
  }

  /// Sign out of an account without removing it. Clears stored credentials so
  /// the account will require re-authentication on next use.
  Future<void> signOutAccount(String accountId) async {
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx == -1) return;
    await _clearCredentials(_accounts[idx]);
  }

  /// Re-authenticate the active Microsoft or Gmail account via OAuth.
  Future<void> reauthenticateActiveOAuth() async {
    if (_authService == null) throw StateError('No active account');
    await _authService!.signIn();
  }

  /// Re-authenticate an IMAP account by saving the supplied password.
  Future<void> reauthenticateImapAccount(
      String accountId, String password) async {
    final credStorage = ImapCredentialStorage(_secureStorage);
    await credStorage.savePassword(accountId, password);
    if (activeAccount?.id == accountId) {
      _buildDatasourcesForActiveAccount();
    }
  }

  /// Build an [EmailRemoteDatasource] for [account] without changing the active account.
  EmailRemoteDatasource buildEmailDatasourceForAccount(Account account) {
    switch (account) {
      case MicrosoftAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: account.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: tokenStorage,
        );
        return GraphApiDatasourceImpl(
            client: GraphHttpClient(
          authService: authSvc,
          onAuthFailure: () => _authFailureController.add(account.id),
        ));

      case GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = GmailAuthService(
          clientId: _googleClientId ?? AppConfig.gmailClientId,
          clientSecret: _googleClientSecret ?? '',
          redirectUri: AppConfig.gmailRedirectUri,
          tokenStorage: tokenStorage,
        );
        return GmailDatasourceImpl(
            client: GmailHttpClient(
          authService: authSvc,
          onAuthFailure: () => _authFailureController.add(account.id),
        ));

      case ImapAccount():
        final credStorage = ImapCredentialStorage(_secureStorage);
        return ImapDatasourceImpl(
          account: account,
          credentialStorage: credStorage,
        );
    }
  }

  /// If the active Microsoft account has no stored email address, fetch it from
  /// the Graph API profile endpoint and persist it. Fails silently.
  Future<void> _backfillActiveAccountEmailIfNeeded() async {
    final account = activeAccount;
    if (account is! MicrosoftAccount || account.emailAddress.isNotEmpty) return;
    try {
      final ds = _emailDatasource;
      if (ds is! GraphApiDatasourceImpl) return;
      final profile = await ds.fetchUserProfile();
      if (profile.email.isEmpty) return;
      await updateAccount(account.copyWith(emailAddress: profile.email));
    } catch (_) {}
  }

  void _sortAccounts() {
    if (_accounts.isEmpty) return;

    final active = activeAccount;

    _accounts.sort((a, b) {
      final nameA = (a.displayName.isEmpty ? a.emailAddress : a.displayName)
          .toLowerCase();
      final nameB = (b.displayName.isEmpty ? b.emailAddress : b.displayName)
          .toLowerCase();
      return nameA.compareTo(nameB);
    });

    if (active != null) {
      _activeIndex = _accounts.indexOf(active);
    }
  }

  void _buildDatasourcesForActiveAccount() {
    final account = activeAccount;
    if (account == null) return;

    final old = _emailDatasource;
    if (old is ImapDatasourceImpl) old.disconnect();

    switch (account) {
      case MicrosoftAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: account.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: tokenStorage,
        );
        final httpClient = GraphHttpClient(
          authService: authSvc,
          onAuthFailure: () => _authFailureController.add(account.id),
        );
        final ds = GraphApiDatasourceImpl(client: httpClient);
        _authService = authSvc;
        _emailDatasource = ds;
        _calendarDatasource = ds;
        _tasksDatasource = ds;
      case GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = GmailAuthService(
          clientId: _googleClientId ?? AppConfig.gmailClientId,
          clientSecret: _googleClientSecret ?? '',
          redirectUri: AppConfig.gmailRedirectUri,
          tokenStorage: tokenStorage,
        );
        void onGmailAuthFailure() => _authFailureController.add(account.id);
        final gmailClient = GmailHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
        );
        final calendarClient = GoogleCalendarHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
        );
        final tasksClient = GoogleTasksHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
        );
        _authService = authSvc;
        _emailDatasource = GmailDatasourceImpl(client: gmailClient);
        _calendarDatasource =
            GoogleCalendarDatasourceImpl(client: calendarClient);
        _tasksDatasource = GoogleTasksDatasourceImpl(client: tasksClient);
      case ImapAccount():
        final credStorage = ImapCredentialStorage(_secureStorage);
        _authService = ImapAuthService(
          accountId: account.id,
          credentialStorage: credStorage,
        );
        _emailDatasource = ImapDatasourceImpl(
          account: account,
          credentialStorage: credStorage,
        );
        _tasksDatasource = null;
        _calendarDatasource = buildCalendarDatasourceForAccount(account);
    }
  }

  /// Build a [CalendarRemoteDatasource] for [account] without changing the
  /// active account or touching [_emailDatasource]/[_tasksDatasource].
  ///
  /// Used by background/periodic reminder reconciliation, which needs every
  /// configured account's calendar, not just the active one (mirrors
  /// [buildEmailDatasourceForAccount]). Deliberately NOT used by
  /// [_buildDatasourcesForActiveAccount]'s Microsoft/Gmail branches, which
  /// share a single client instance across email/calendar/tasks for the
  /// active account already — routing them through this method too would
  /// construct a second, redundant auth/client pipeline for the same account.
  CalendarRemoteDatasource? buildCalendarDatasourceForAccount(Account account) {
    switch (account) {
      case MicrosoftAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: account.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: tokenStorage,
        );
        return GraphApiDatasourceImpl(
          client: GraphHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(account.id),
          ),
        );
      case GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = GmailAuthService(
          clientId: _googleClientId ?? AppConfig.gmailClientId,
          clientSecret: _googleClientSecret ?? '',
          redirectUri: AppConfig.gmailRedirectUri,
          tokenStorage: tokenStorage,
        );
        return GoogleCalendarDatasourceImpl(
          client: GoogleCalendarHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(account.id),
          ),
        );
      case ImapAccount():
        return _buildImapCalendarDatasource(account);
    }
  }

  CalendarRemoteDatasource? _buildImapCalendarDatasource(ImapAccount account) {
    final config = account.nextcloudCalendarConfig;
    if (config != null) {
      final caldavCreds = CalDavCredentialStorage(_secureStorage);
      return CalDavCalendarDatasourceImpl(
        serverUrl: config.serverUrl,
        username: config.username,
        passwordProvider: () => caldavCreds.loadPassword(account.id),
      );
    }
    if (!kIsWeb && (Platform.isMacOS || Platform.isIOS)) {
      return EventKitCalendarDatasourceImpl();
    }
    return null;
  }

  Future<String?> loadCalDavPassword(String accountId) async {
    final credStorage = CalDavCredentialStorage(_secureStorage);
    return credStorage.loadPassword(accountId);
  }

  Future<void> saveCalDavPassword(String accountId, String password) async {
    final credStorage = CalDavCredentialStorage(_secureStorage);
    await credStorage.savePassword(accountId, password);
    if (activeAccount?.id == accountId) {
      _buildDatasourcesForActiveAccount();
    }
  }

  Future<bool> _hasCredentials(Account account) async {
    switch (account) {
      case MicrosoftAccount() || GmailAccount():
        final ts = TokenStorage(_secureStorage,
            storageKey: 'token_${account.id}');
        final token = await ts.loadToken();
        if (token == null) return false;
        // An expired token with no refresh token cannot be renewed silently;
        // treat it as unauthenticated so the sign-in prompt appears immediately
        // instead of a dead-end folder-list error.
        return !token.isExpired || token.refreshToken != null;
      case ImapAccount():
        final cs = ImapCredentialStorage(_secureStorage);
        return await cs.loadPassword(account.id) != null;
    }
  }

  Future<void> _clearCredentials(Account account) async {
    switch (account) {
      case MicrosoftAccount() || GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        await tokenStorage.clearToken();
      case ImapAccount():
        final credStorage = ImapCredentialStorage(_secureStorage);
        await credStorage.deletePassword(account.id);
        final caldavCreds = CalDavCredentialStorage(_secureStorage);
        await caldavCreds.deletePassword(account.id);
    }
  }

  /// One-time migration: if a legacy single-account token exists (from before
  /// multi-account support), convert it into a MicrosoftAccount entry.
  Future<void> _migrateLegacyAccount() async {
    final legacyStorage = TokenStorage(_secureStorage);
    final token = await legacyStorage.loadToken();
    if (token == null) return;

    const uuid = Uuid();
    final id = uuid.v4();

    final newStorage = TokenStorage(_secureStorage, storageKey: 'token_$id');
    await newStorage.saveToken(token);
    await legacyStorage.clearToken();

    final account = MicrosoftAccount(
      id: id,
      displayName: 'Microsoft Account',
      emailAddress: '',
      tenantId: AppConfig.microsoftTenantId,
    );

    await _accountStorage.saveAccounts([account]);
    await _accountStorage.saveActiveIndex(0);
  }
}
