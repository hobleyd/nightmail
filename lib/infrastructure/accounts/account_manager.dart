import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../core/config/app_config.dart';
import '../../core/config/oauth_client_id_storage.dart';
import '../../data/datasources/remote/caldav_calendar_datasource_impl.dart';
import '../../data/datasources/remote/cloud_drive_datasource.dart';
import '../../data/datasources/remote/calendar_remote_datasource.dart';
import '../../data/datasources/remote/email_remote_datasource.dart';
import '../../data/datasources/remote/eventkit_calendar_datasource_impl.dart';
import '../../data/datasources/remote/gmail_contacts_datasource_impl.dart';
import '../../data/datasources/remote/gmail_datasource_impl.dart';
import '../../data/datasources/remote/google_calendar_datasource_impl.dart';
import '../../data/datasources/remote/google_drive_datasource_impl.dart';
import '../../data/datasources/remote/google_tasks_datasource_impl.dart';
import '../../data/datasources/remote/graph_api_datasource_impl.dart';
import '../../data/datasources/remote/graph_drive_datasource_impl.dart';
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
import '../http/google_drive_http_client.dart';
import '../http/google_people_http_client.dart';
import '../http/google_tasks_http_client.dart';
import '../http/graph_http_client.dart';
import '../../domain/entities/cloud_document.dart';
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

  // Mirror of [authFailures]: fired by AuthInterceptor whenever a usable token
  // is obtained for an account, so the UI can clear a stale "needs reauth" flag
  // that a transient failure latched (see AccountCubit._onAuthSuccess).
  final _authSuccessController = StreamController<String>.broadcast();
  Stream<String> get authSuccesses => _authSuccessController.stream;

  final _readyCompleter = Completer<void>();

  /// Completes the first time [initialize] finishes, so background work that
  /// needs the account list can start without racing the UI's own init or
  /// calling [initialize] a second time. Never completes if [initialize]
  /// throws — await it with a timeout.
  Future<void> get ready => _readyCompleter.future;

  // Lazily built and cached per Gmail account ID so contact search works for
  // any account regardless of which one is currently active.
  final Map<String, GmailContactsDatasourceImpl> _contactsDatasourceCache = {};

  // Lazily built and cached per Microsoft account ID so directory profile
  // lookups (contact hover card) work for any account, not just the active
  // one. Reuses GraphApiDatasourceImpl since directory lookups hit the same
  // Graph host/auth as email.
  final Map<String, GraphApiDatasourceImpl> _directoryDatasourceCache = {};

  // Lazily built and cached per IMAP account ID. Unlike the Graph/Gmail
  // branches of buildEmailDatasourceForAccount (stateless HTTP clients — a
  // fresh one each call is harmless), ImapDatasourceImpl holds a persistent
  // ImapClient/TCP connection. Building a new instance on every poll leaked a
  // connection per cycle with no disconnect(), eventually hitting the
  // server's per-user connection cap.
  final Map<String, ImapDatasourceImpl> _imapDatasourceCache = {};

  List<Account> get accounts => List.unmodifiable(_accounts);
  bool get hasAccounts => _accounts.isNotEmpty;
  int get activeIndex => _activeIndex;

  Account? get activeAccount =>
      _accounts.isEmpty ? null : _accounts[_activeIndex];

  /// The configured account with [id], or null when [id] is null or unknown.
  ///
  /// Needed by anything that acts on a specific account rather than the active
  /// one — sub-windows in particular, which run their own engine and restore
  /// whichever account was persisted as active, not the one the window was
  /// opened for.
  Account? accountById(String? id) {
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

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
      accountEmail: account.emailAddress,
    );
    final ds = GmailContactsDatasourceImpl(
      client: GooglePeopleHttpClient(
        authService: authSvc,
        onAuthFailure: () => _authFailureController.add(accountId),
        onAuthSuccess: () => _authSuccessController.add(accountId),
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
    final cfg = _microsoftAuthConfig(account);
    final authSvc = MicrosoftAuthService(
      clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
      tenantId: cfg.tenantId,
      redirectUri: AppConfig.microsoftRedirectUri,
      tokenStorage: cfg.tokenStorage,
    );
    final ds = GraphApiDatasourceImpl(
      mailboxAddress: cfg.mailboxAddress,
      client: GraphHttpClient(
        authService: authSvc,
        onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
        onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
      ),
    );
    _directoryDatasourceCache[accountId] = ds;
    return ds;
  }

  /// Resolves how to authenticate a Graph call for [account]: which token to
  /// use, which tenant, and which mailbox path to hit.
  ///
  /// A shared mailbox ([MicrosoftAccount.parentAccountId] set) has no OAuth
  /// credentials of its own — every field here follows the parent account's
  /// token, and [mailboxAddress] carries the shared mailbox's own address so
  /// GraphApiDatasourceImpl targets `/users/{mailboxAddress}/...` instead of
  /// `/me/...`. [credentialOwnerId] is who a 401 should actually flag for
  /// re-auth — always the parent for a shared mailbox, which owns no
  /// credentials of its own to invalidate.
  ({
    TokenStorage tokenStorage,
    String tenantId,
    String credentialOwnerId,
    String? mailboxAddress,
  }) _microsoftAuthConfig(MicrosoftAccount account) {
    final ownerId = account.parentAccountId ?? account.id;
    return (
      tokenStorage: TokenStorage(_secureStorage, storageKey: 'token_$ownerId'),
      tenantId: account.tenantId,
      credentialOwnerId: ownerId,
      mailboxAddress:
          account.parentAccountId != null ? account.emailAddress : null,
    );
  }

  AuthService get activeAuthService {
    if (_authService == null) throw StateError('No active account');
    return _authService!;
  }

  /// Best-effort fetch of the account holder's own profile fields (name, job
  /// title, phone numbers) from the account's directory API, to prefill the
  /// Settings "Profile" section. Returns null for IMAP accounts, an unknown
  /// account ID, or if the underlying API call fails (e.g. scope not granted).
  Future<
      ({
        String firstName,
        String lastName,
        String jobTitle,
        String phone,
        String mobile
      })?> fetchOwnProfileFields(String accountId) async {
    final account = _accounts.cast<Account?>().firstWhere(
      (a) => a?.id == accountId,
      orElse: () => null,
    );
    try {
      switch (account) {
        case MicrosoftAccount():
          return await directoryDatasourceForAccount(accountId)
              ?.fetchOwnSignatureProfile();
        case GmailAccount():
          return await contactsDatasourceForAccount(accountId)
              ?.fetchOwnSignatureProfile();
        case ImapAccount():
        case null:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Cloud document preview (SharePoint/OneDrive and Google Drive body links)
  // ---------------------------------------------------------------------------

  // Lazily built and cached per account ID, like the contacts and directory
  // caches above: a drive datasource is a stateless HTTP client, but the
  // service it talks to has nothing to do with which account is active — a
  // Drive link routinely arrives in an Exchange mailbox and vice versa.
  final Map<String, CloudDriveDatasource> _driveDatasourceCache = {};

  /// The accounts that could fetch a [provider] document, in the order to try
  /// them: the active account first when it is one of them, since it is the
  /// likeliest to have access to something its own mail linked to.
  ///
  /// Shared Microsoft mailboxes are skipped — they hold no credentials of their
  /// own, and the parent account is already in the list.
  List<Account> cloudDriveCandidates(CloudDriveProvider provider) {
    bool matches(Account a) => switch (provider) {
          CloudDriveProvider.microsoft =>
            a is MicrosoftAccount && a.parentAccountId == null,
          CloudDriveProvider.google => a is GmailAccount,
        };
    final active = activeAccount;
    return [
      if (active != null && matches(active)) active,
      ..._accounts.where((a) => matches(a) && a.id != active?.id),
    ];
  }

  /// Whether [accountId]'s stored token already carries the provider's
  /// file-read scope.
  ///
  /// The token *is* the record of what was consented to — both providers echo
  /// the granted scopes back on every token and refresh response — so there is
  /// no separate flag here to drift out of step with the real grant.
  Future<bool> hasCloudDriveAccess(String accountId) async {
    final account = accountById(accountId);
    final authService = account == null ? null : _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService.grantsFileAccess(token.scope),
      GmailAccount() => GmailAuthService.grantsFileAccess(token.scope),
      _ => false,
    };
  }

  /// Runs the interactive sign-in again for [accountId], this time also asking
  /// for read access to that provider's files.
  ///
  /// Returns whether the scope came back granted — the user can decline it in
  /// the browser, and the flow itself still "succeeds". Nothing else about the
  /// account changes: the new token lands under the same per-account key with
  /// its existing scopes intact (Microsoft re-requests the base set, Google is
  /// told `include_granted_scopes`).
  Future<bool> requestCloudDriveAccess(String accountId) async {
    final account = accountById(accountId);
    if (account == null) throw StateError('Unknown account: $accountId');

    // Settings can edit the OAuth client IDs; pick up any change first, as the
    // other interactive paths do.
    await _loadAndMigrateClientIds();

    final tokenStorage =
        TokenStorage(_secureStorage, storageKey: 'token_${account.id}');
    final AuthService authService;
    switch (account) {
      case MicrosoftAccount():
        authService = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: account.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: tokenStorage,
          extraScopes: const [MicrosoftAuthService.filesReadScope],
        );
      case GmailAccount():
        authService = GmailAuthService(
          clientId: _googleClientId ?? AppConfig.gmailClientId,
          clientSecret: _googleClientSecret ?? '',
          redirectUri: AppConfig.gmailRedirectUri,
          tokenStorage: tokenStorage,
          accountEmail: account.emailAddress,
          extraScopes: const [GmailAuthService.driveReadonlyScope],
        );
      case ImapAccount():
        return false;
    }

    final token = await authService.signIn();
    // The datasource caches hold clients built around the old token's storage
    // key, which is unchanged — but the active account's pipeline is rebuilt
    // for the same reason reauthenticateOAuthAccount does it: so the new token
    // is used now rather than after the next refresh cycle.
    if (accountId == activeAccount?.id) _buildDatasourcesForActiveAccount();

    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService.grantsFileAccess(token.scope),
      GmailAccount() => GmailAuthService.grantsFileAccess(token.scope),
      ImapAccount() => false,
    };
  }

  /// A datasource that can fetch cloud documents as [accountId], or null when
  /// that account belongs to neither drive provider.
  CloudDriveDatasource? cloudDriveDatasourceForAccount(String accountId) {
    final cached = _driveDatasourceCache[accountId];
    if (cached != null) return cached;

    final account = accountById(accountId);
    if (account == null) return null;

    final CloudDriveDatasource datasource;
    switch (account) {
      case MicrosoftAccount():
        final cfg = _microsoftAuthConfig(account);
        datasource = GraphDriveDatasourceImpl(
          client: GraphHttpClient(
            authService: MicrosoftAuthService(
              clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
              tenantId: cfg.tenantId,
              redirectUri: AppConfig.microsoftRedirectUri,
              tokenStorage: cfg.tokenStorage,
            ),
            onAuthFailure: () =>
                _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () =>
                _authSuccessController.add(cfg.credentialOwnerId),
          ),
        );
      case GmailAccount():
        datasource = GoogleDriveDatasourceImpl(
          client: GoogleDriveHttpClient(
            authService: GmailAuthService(
              clientId: _googleClientId ?? AppConfig.gmailClientId,
              clientSecret: _googleClientSecret ?? '',
              redirectUri: AppConfig.gmailRedirectUri,
              tokenStorage: TokenStorage(_secureStorage,
                  storageKey: 'token_${account.id}'),
              accountEmail: account.emailAddress,
            ),
            onAuthFailure: () => _authFailureController.add(account.id),
            onAuthSuccess: () => _authSuccessController.add(account.id),
          ),
        );
      case ImapAccount():
        return null;
    }
    _driveDatasourceCache[accountId] = datasource;
    return datasource;
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
    }
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
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

  /// Looks up [email] in [parentAccountId]'s directory and, if found, probes
  /// whether its mailbox is actually reachable with the current token.
  ///
  /// The two checks Graph offers in place of the "list shared mailboxes I can
  /// add" API it doesn't have (see MicrosoftAuthService's `.Shared` scopes):
  /// a directory lookup finds the display name for any address, and only the
  /// probe says whether Exchange has actually granted Full Access. Returns
  /// null if [email] isn't in [parentAccountId]'s directory, or if
  /// [parentAccountId] isn't a Microsoft account with a usable token.
  ///
  /// A token refresh renews the existing grant, it does not widen it — an
  /// account authorised before the `.Shared` scopes were added keeps a token
  /// that will never carry them until the user re-authenticates from
  /// Settings. Probing that token anyway would 403 and read exactly like "no
  /// Full Access grant", which is the wrong diagnosis and sends the user to
  /// ask an admin for something they already have; [needsReauth] lets the
  /// caller tell the two apart. Checked before the directory lookup, not
  /// just for testability: there is no point spending a round trip on a
  /// request that cannot succeed. One consequence — a typo'd address on a
  /// stale-scope account reads "needs re-authenticating" rather than "not
  /// found in the directory", which is fine, since re-authenticating is
  /// required either way before anything here can work.
  Future<({String displayName, bool hasAccess, bool needsReauth})?>
      resolveSharedMailboxCandidate(
    String parentAccountId,
    String email,
  ) async {
    final ds = directoryDatasourceForAccount(parentAccountId);
    if (ds == null) return null;

    final scope = await _storedScope(parentAccountId);
    if (scope != null && !scope.contains('Mail.Read.Shared')) {
      return (displayName: email, hasAccess: false, needsReauth: true);
    }

    final profile = await ds.fetchDirectoryProfile(email);
    if (profile == null) return null;
    final displayName = profile.name ?? email;

    final hasAccess = await ds.probeSharedMailboxAccess(email);
    return (displayName: displayName, hasAccess: hasAccess, needsReauth: false);
  }

  Future<String?> _storedScope(String accountId) async {
    final ts = TokenStorage(_secureStorage, storageKey: 'token_$accountId');
    final token = await ts.loadToken();
    return token?.scope;
  }

  /// Adds [email] as a shared mailbox riding on [parentAccountId]'s
  /// credentials and makes it the active account.
  ///
  /// Callers must have already confirmed access via
  /// [resolveSharedMailboxCandidate] — this does not probe again, so pointing
  /// it at a mailbox the parent cannot actually reach adds an account that
  /// will 403 on every request.
  Future<Account> addSharedMailbox({
    required String parentAccountId,
    required String email,
    required String displayName,
  }) async {
    final parent = accountById(parentAccountId);
    if (parent is! MicrosoftAccount) {
      throw StateError('Unknown Microsoft account: $parentAccountId');
    }
    const uuid = Uuid();
    final account = MicrosoftAccount(
      id: uuid.v4(),
      displayName: displayName,
      emailAddress: email,
      tenantId: parent.tenantId,
      parentAccountId: parentAccountId,
    );
    await addAccount(account);
    return account;
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
  ///
  /// Cascades to any shared mailboxes riding on this account's credentials
  /// ([MicrosoftAccount.parentAccountId]) — orphaning one instead would leave
  /// it pointing at a token that no longer exists.
  Future<void> removeAccount(String accountId) async {
    final children = _accounts
        .whereType<MicrosoftAccount>()
        .where((a) => a.parentAccountId == accountId)
        .map((a) => a.id)
        .toList();
    for (final childId in children) {
      await removeAccount(childId);
    }

    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx == -1) return;

    await _clearCredentials(_accounts[idx]);
    _contactsDatasourceCache.remove(accountId);
    _directoryDatasourceCache.remove(accountId);
    await _imapDatasourceCache.remove(accountId)?.disconnect();

    final updated = [..._accounts]..removeAt(idx);
    _accounts = updated;
    if (_accounts.isEmpty) {
      _activeIndex = 0;
      _emailDatasource = null;
      _calendarDatasource = null;
      _contactsDatasourceCache.clear();
      _directoryDatasourceCache.clear();
      for (final ds in _imapDatasourceCache.values) {
        await ds.disconnect();
      }
      _imapDatasourceCache.clear();
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

  /// Re-authenticate a specific Microsoft or Gmail account via OAuth, active or
  /// not. Throws [StateError] for an unknown id or a non-OAuth account.
  ///
  /// [reauthenticateActiveOAuth] can only reach the active account's auth
  /// service, but Settings lets any configured account be selected, and consent
  /// is per-account — when the app starts requesting a new provider scope, every
  /// account has to be taken through the flow separately.
  ///
  /// Deliberately does not clear the stored token first: `signIn()` performs a
  /// full interactive authorization (Gmail sends `prompt=consent`, so new scopes
  /// are re-consented), and leaving the existing token in place means a
  /// cancelled or failed sign-in leaves a working account behind rather than a
  /// locked-out one.
  Future<void> reauthenticateOAuthAccount(String accountId) async {
    final account = accountById(accountId);
    if (account == null) throw StateError('Unknown account: $accountId');

    // A shared mailbox has no credentials of its own to renew — the token
    // that needs refreshing belongs to whichever account it rides on.
    if (account is MicrosoftAccount && account.parentAccountId != null) {
      return reauthenticateOAuthAccount(account.parentAccountId!);
    }

    // Settings can edit the OAuth client IDs, so pick up any change made since
    // the last load before building the service (as addAccount does).
    await _loadAndMigrateClientIds();

    final authService = _buildOAuthServiceForAccount(account);
    if (authService == null) {
      throw StateError('${account.emailAddress} does not sign in with OAuth');
    }
    await authService.signIn();

    // The new token lands under the same per-account storage key, so existing
    // datasources would pick it up anyway; rebuilding the active account's
    // pipeline just avoids waiting on a refresh cycle to notice.
    if (accountId == activeAccount?.id) _buildDatasourcesForActiveAccount();
  }

  /// The OAuth service for [account], or null for account types that do not use
  /// OAuth (IMAP, which authenticates with a stored password).
  AuthService? _buildOAuthServiceForAccount(Account account) {
    final tokenStorage = TokenStorage(
      _secureStorage,
      storageKey: 'token_${account.id}',
    );
    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: account.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: tokenStorage,
        ),
      // The email is what lets a Workspace account pick up the room-directory
      // scope on re-auth; see GmailAuthService._requestedScopes.
      GmailAccount() => GmailAuthService(
          clientId: _googleClientId ?? AppConfig.gmailClientId,
          clientSecret: _googleClientSecret ?? '',
          redirectUri: AppConfig.gmailRedirectUri,
          tokenStorage: tokenStorage,
          accountEmail: account.emailAddress,
        ),
      ImapAccount() => null,
    };
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
        final cfg = _microsoftAuthConfig(account);
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: cfg.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: cfg.tokenStorage,
        );
        return GraphApiDatasourceImpl(
            mailboxAddress: cfg.mailboxAddress,
            client: GraphHttpClient(
          authService: authSvc,
          onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
          onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
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
          accountEmail: account.emailAddress,
        );
        return GmailDatasourceImpl(
          client: GmailHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(account.id),
            onAuthSuccess: () => _authSuccessController.add(account.id),
          ),
          displayName: account.senderName,
        );

      case ImapAccount():
        final cached = _imapDatasourceCache[account.id];
        if (cached != null) return cached;
        final credStorage = ImapCredentialStorage(_secureStorage);
        final ds = ImapDatasourceImpl(
          account: account,
          credentialStorage: credStorage,
        );
        _imapDatasourceCache[account.id] = ds;
        return ds;
    }
  }

  /// Public trigger for the email backfill, called from secondary windows where
  /// the stored account might still have an empty email from legacy migration.
  Future<void> ensureEmailPopulated() => _backfillActiveAccountEmailIfNeeded();

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
        final cfg = _microsoftAuthConfig(account);
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: cfg.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: cfg.tokenStorage,
        );
        final httpClient = GraphHttpClient(
          authService: authSvc,
          onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
          onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
        );
        final ds = GraphApiDatasourceImpl(
          client: httpClient,
          mailboxAddress: cfg.mailboxAddress,
        );
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
          accountEmail: account.emailAddress,
        );
        void onGmailAuthFailure() => _authFailureController.add(account.id);
        void onGmailAuthSuccess() => _authSuccessController.add(account.id);
        final gmailClient = GmailHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
          onAuthSuccess: onGmailAuthSuccess,
        );
        final calendarClient = GoogleCalendarHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
          onAuthSuccess: onGmailAuthSuccess,
        );
        final tasksClient = GoogleTasksHttpClient(
          authService: authSvc,
          onAuthFailure: onGmailAuthFailure,
          onAuthSuccess: onGmailAuthSuccess,
        );
        _authService = authSvc;
        _emailDatasource = GmailDatasourceImpl(
          client: gmailClient,
          displayName: account.senderName,
        );
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
        final cfg = _microsoftAuthConfig(account);
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: cfg.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: cfg.tokenStorage,
        );
        return GraphApiDatasourceImpl(
          mailboxAddress: cfg.mailboxAddress,
          client: GraphHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
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
          accountEmail: account.emailAddress,
        );
        return GoogleCalendarDatasourceImpl(
          client: GoogleCalendarHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(account.id),
            onAuthSuccess: () => _authSuccessController.add(account.id),
          ),
        );
      case ImapAccount():
        return _buildImapCalendarDatasource(account);
    }
  }

  /// Build a [TasksRemoteDatasource] for [account] without changing the active
  /// account or touching [_emailDatasource]/[_calendarDatasource].
  ///
  /// The tasks counterpart of [buildCalendarDatasourceForAccount], and used the
  /// same way: by periodic/background due-task reconciliation, which needs
  /// every configured account's tasks rather than only the active one. IMAP
  /// accounts have no tasks provider, so they return null.
  TasksRemoteDatasource? buildTasksDatasourceForAccount(Account account) {
    switch (account) {
      case MicrosoftAccount():
        final cfg = _microsoftAuthConfig(account);
        final authSvc = MicrosoftAuthService(
          clientId: _microsoftClientId ?? AppConfig.microsoftClientId,
          tenantId: cfg.tenantId,
          redirectUri: AppConfig.microsoftRedirectUri,
          tokenStorage: cfg.tokenStorage,
        );
        return GraphApiDatasourceImpl(
          mailboxAddress: cfg.mailboxAddress,
          client: GraphHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
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
          accountEmail: account.emailAddress,
        );
        return GoogleTasksDatasourceImpl(
          client: GoogleTasksHttpClient(
            authService: authSvc,
            onAuthFailure: () => _authFailureController.add(account.id),
            onAuthSuccess: () => _authSuccessController.add(account.id),
          ),
        );
      case ImapAccount():
        return null;
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
      // A shared mailbox owns no token of its own — it is only ever as
      // authenticated as the parent account whose credentials it rides on.
      case MicrosoftAccount(parentAccountId: final parentId?):
        final parent = accountById(parentId);
        return parent != null && await _hasCredentials(parent);
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
      // Never clear the parent's token as a side effect of removing/signing
      // out of a shared mailbox — it isn't this account's to clear, and doing
      // so would sign the parent out too.
      case MicrosoftAccount(parentAccountId: != null):
        return;
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
