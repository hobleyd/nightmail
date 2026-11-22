import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:fpdart/fpdart.dart' show Either;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../../data/datasources/remote/change_stream_datasource.dart';
import '../sync/change_stream_service.dart';
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
import '../auth/auth_token.dart';
import '../auth/caldav_credential_storage.dart';
import '../auth/gmail_auth_service.dart';
import '../auth/imap_auth_service.dart';
import '../auth/imap_credential_storage.dart';
import '../auth/microsoft_auth_service.dart';
import '../auth/sign_in_identity.dart';
import '../auth/signed_in_mailbox_lookup.dart';
import '../auth/token_storage.dart';
import '../http/gmail_http_client.dart';
import '../http/google_calendar_http_client.dart';
import '../http/google_drive_http_client.dart';
import '../http/google_people_http_client.dart';
import '../http/google_tasks_http_client.dart';
import '../http/graph_http_client.dart';
import '../../core/utils/cloud_document_link.dart';
import '../../domain/entities/cloud_document.dart';
import '../../domain/entities/cloud_file.dart';
import '../../domain/entities/graph_endpoints.dart';
import '../../core/error/failures.dart';
import 'account.dart';
import 'account_storage.dart';
import 'file_sites_refresh.dart';

class AccountManager {
  AccountManager({
    required this._accountStorage,
    required this._secureStorage,
    required this._clientIdStorage,
    Future<List<String>> Function(Account account)? mailboxAddresses,
  }) : _mailboxAddressesOverride = mailboxAddresses;

  final AccountStorage _accountStorage;
  final FlutterSecureStorage _secureStorage;
  // Only read once, in initialize()'s one-time migration — see
  // _migrateSharedClientIdsToAccounts. Client ID/Secret/Tenant ID otherwise
  // live on the Account itself (MicrosoftAccount.clientId, GmailAccount.
  // clientId/clientSecret) now, not here.
  final OAuthClientIdStorage _clientIdStorage;

  /// What the provider says a stored account's mailbox answers for, asked with
  /// the account's own credentials — or a canned answer, in tests. See
  /// [ensureEmailPopulated].
  final Future<List<String>> Function(Account account)?
      _mailboxAddressesOverride;

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
  // is obtained for an account, and by a verified interactive sign-in
  // (_signInExistingAccount), so the UI can clear a "needs reauth" flag the
  // moment it stops being true — whether a transient failure latched it (see
  // AccountCubit._onAuthSuccess) or the user has just signed in again (see
  // MailPollerCubit._onAuthSuccess).
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

  // What each Gmail account's label counts were last read as, and the point in
  // the mailbox's history they were read at. The datasource itself is rebuilt
  // per call, so this is what lets a folder-list load re-read only the labels
  // whose counts can have moved since the last one — see
  // GmailDatasourceImpl._refreshLabelCounts.
  final Map<String, GmailLabelCountMemo> _labelCountMemos = {};

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
      clientId: account.clientId ?? AppConfig.gmailClientId,
      clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
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
    final authSvc = _microsoftAuthServiceFor(cfg);
    final ds = GraphApiDatasourceImpl(
      betaBaseUrl: cfg.endpoints.graphBetaBaseUrl,
      mailboxAddress: cfg.mailboxAddress,
      client: GraphHttpClient(
        authService: authSvc,
        onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
        onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
        baseUrl: cfg.endpoints.graphBaseUrl,
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
  ///
  /// [endpoints] are the credential owner's too: a shared mailbox is reached
  /// through the same server its parent signed in to, whatever copy it holds.
  ({
    TokenStorage tokenStorage,
    String tenantId,
    String? clientId,
    GraphEndpoints endpoints,
    String credentialOwnerId,
    String? mailboxAddress,
  })
  _microsoftAuthConfig(MicrosoftAccount account) {
    final ownerId = account.parentAccountId ?? account.id;
    final owner = _credentialOwnerFor(account);
    return (
      tokenStorage: TokenStorage(_secureStorage, storageKey: 'token_$ownerId'),
      tenantId: account.tenantId,
      clientId: account.clientId,
      endpoints: (owner is MicrosoftAccount ? owner : account).endpoints,
      credentialOwnerId: ownerId,
      mailboxAddress: account.parentAccountId != null
          ? account.emailAddress
          : null,
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
      String mobile,
    })?
  >
  fetchOwnProfileFields(String accountId) async {
    final account = _accounts.cast<Account?>().firstWhere(
      (a) => a?.id == accountId,
      orElse: () => null,
    );
    try {
      switch (account) {
        case MicrosoftAccount():
          return await directoryDatasourceForAccount(
            accountId,
          )?.fetchOwnSignatureProfile();
        case GmailAccount():
          return await contactsDatasourceForAccount(
            accountId,
          )?.fetchOwnSignatureProfile();
        case ImapAccount():
        case null:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Runs Settings' "Fetch from Microsoft/Google" for [accountId] without the
  /// user asking: fetches the account holder's directory profile and persists
  /// any field that is still blank on the stored account. Meant for a freshly
  /// added account, so the Profile section (and the signature merge tags it
  /// feeds) start out populated rather than empty.
  ///
  /// Only blank fields are filled — a value the user has already typed is
  /// never overwritten — and the stored account is re-read after the network
  /// round trip so a concurrent edit is not clobbered. Returns whether
  /// anything was saved; false for IMAP accounts, shared mailboxes (whose
  /// token belongs to someone else's profile), and any fetch failure.
  Future<bool> prefillOwnProfileFields(String accountId) async {
    final account = accountById(accountId);
    if (account is MicrosoftAccount && account.parentAccountId != null) {
      return false;
    }
    final profile = await fetchOwnProfileFields(accountId);
    if (profile == null) return false;

    final current = accountById(accountId);
    if (current == null) return false;

    String fill(String existing, String fetched) =>
        existing.isEmpty && fetched.isNotEmpty ? fetched : existing;
    final updated = current.copyWith(
      firstName: fill(current.firstName, profile.firstName),
      lastName: fill(current.lastName, profile.lastName),
      jobTitle: fill(current.jobTitle, profile.jobTitle),
      phone: fill(current.phone, profile.phone),
      mobile: fill(current.mobile, profile.mobile),
    );
    if (updated == current) return false;

    await updateAccount(updated);
    return true;
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
  ///
  /// A Nextcloud link ([url]) goes only to the NightMail Servers whose
  /// advertised file sites it lies on: two servers' Nextclouds have nothing to
  /// do with each other, and asking the wrong one is a guaranteed 404.
  List<Account> cloudDriveCandidates(CloudDriveProvider provider,
      {String? url}) {
    bool matches(Account a) => switch (provider) {
      // A NightMail Server has no SharePoint/OneDrive behind it, and would
      // refuse Files.Read.All as a scope it never published.
      CloudDriveProvider.microsoft => a is MicrosoftAccount &&
          a.parentAccountId == null &&
          !a.isNightmailServer,
      CloudDriveProvider.google => a is GmailAccount,
      CloudDriveProvider.nextcloud => a is MicrosoftAccount &&
          a.parentAccountId == null &&
          a.isNightmailServer &&
          url != null &&
          parseCloudDocumentLink(url,
                      nextcloudBaseUrls: a.endpoints.filesBaseUrls)
                  ?.provider ==
              CloudDriveProvider.nextcloud,
    };
    final active = activeAccount;
    return [
      if (active != null && matches(active)) active,
      ..._accounts.where((a) => matches(a) && a.id != active?.id),
    ];
  }

  /// Every file site the signed-in NightMail Servers advertise — what the body
  /// link scanner may claim as Nextcloud (`parseCloudDocumentLink`).
  List<String> get nextcloudFileBaseUrls => [
        for (final a in _accounts)
          if (a is MicrosoftAccount &&
              a.parentAccountId == null &&
              a.isNightmailServer)
            ...a.endpoints.filesBaseUrls,
      ];

  /// Whether [accountId]'s stored token already carries the provider's
  /// file-read scope.
  ///
  /// The token *is* the record of what was consented to — both providers echo
  /// the granted scopes back on every token and refresh response — so there is
  /// no separate flag here to drift out of step with the real grant.
  Future<bool> hasCloudDriveAccess(String accountId) async {
    final account = accountById(accountId);
    final authService = account == null
        ? null
        : _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return switch (account) {
      // No scope to ask for: the server's own token reads its file sites, if
      // it publishes any.
      MicrosoftAccount(isNightmailServer: true) =>
        account.endpoints.filesBaseUrls.isNotEmpty,
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

    final extraScopes = switch (account) {
      MicrosoftAccount(isNightmailServer: true) => null,
      MicrosoftAccount() => const [MicrosoftAuthService.filesReadScope],
      GmailAccount() => const [GmailAuthService.driveReadonlyScope],
      ImapAccount() => null,
    };
    if (extraScopes == null) return false;

    final token =
        await _signInExistingAccount(account, extraScopes: extraScopes);
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

  /// The accounts the compose window's cloud file picker can browse, active
  /// account first: every Microsoft 365 and Gmail account, and each NightMail
  /// Server that fronts a Nextcloud (publishes file sites). Shared Microsoft
  /// mailboxes are left out — they hold no drive of their own.
  Future<List<CloudFileSource>> cloudFileSources() async {
    CloudDriveProvider? providerOf(Account a) => switch (a) {
          MicrosoftAccount(parentAccountId: final String _) => null,
          MicrosoftAccount(isNightmailServer: true)
              when a.endpoints.filesBaseUrls.isEmpty =>
            null,
          MicrosoftAccount(isNightmailServer: true) =>
            CloudDriveProvider.nextcloud,
          MicrosoftAccount() => CloudDriveProvider.microsoft,
          GmailAccount() => CloudDriveProvider.google,
          ImapAccount() => null,
        };
    final active = activeAccount;
    final ordered = [
      ?active,
      ..._accounts.where((a) => a.id != active?.id),
    ];
    return [
      for (final account in ordered)
        if (providerOf(account) case final provider?)
          CloudFileSource(
            accountId: account.id,
            email: account.emailAddress,
            provider: provider,
            hasReadAccess: await hasCloudDriveAccess(account.id),
          ),
    ];
  }

  /// The mail domains [accountId] answers at — what an "anyone in my
  /// organization" sharing link reaches.
  Set<String> organizationDomainsFor(String accountId) => {
        for (final address in accountById(accountId)?.allAddresses ?? {})
          if (address.contains('@')) address.split('@').last,
      };

  /// Whether [accountId]'s stored token may grant other people access to its
  /// files — the compose window's "share it with them" after linking one.
  ///
  /// A NightMail Server has no incremental consent: its token carries every
  /// scope it published, so whether the share works is the server's answer.
  Future<bool> hasCloudDriveShareAccess(String accountId) async {
    final account = accountById(accountId);
    if (account is MicrosoftAccount && account.isNightmailServer) return true;
    final authService =
        account == null ? null : _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService.grantsFileWrite(token.scope),
      GmailAccount() => GmailAuthService.grantsDriveWrite(token.scope),
      _ => false,
    };
  }

  /// Runs the interactive sign-in again for [accountId], asking for write
  /// access to its files so a linked file can be shared with recipients. Same
  /// shape as [requestCloudDriveAccess]; returns whether it came back granted.
  ///
  /// Microsoft is asked for the read scope alongside the write one: a refresh
  /// re-requests exactly what the token proves, and a token holding only the
  /// write scope would otherwise lose the read one the preview relies on.
  Future<bool> requestCloudDriveShareAccess(String accountId) async {
    final account = accountById(accountId);
    if (account == null) throw StateError('Unknown account: $accountId');
    final extraScopes = switch (account) {
      MicrosoftAccount(isNightmailServer: true) => null,
      MicrosoftAccount() => const [
          MicrosoftAuthService.filesReadScope,
          MicrosoftAuthService.filesReadWriteScope,
        ],
      GmailAccount() => const [GmailAuthService.driveScope],
      ImapAccount() => null,
    };
    if (extraScopes == null) return account is MicrosoftAccount;

    final token =
        await _signInExistingAccount(account, extraScopes: extraScopes);
    if (accountId == activeAccount?.id) _buildDatasourcesForActiveAccount();
    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService.grantsFileWrite(token.scope),
      GmailAccount() => GmailAuthService.grantsDriveWrite(token.scope),
      ImapAccount() => false,
    };
  }

  /// Whether [accountId]'s stored token already carries Gmail's full-mailbox
  /// scope, which is the only one that can permanently delete mail.
  ///
  /// Gmail only: Graph and IMAP both delete permanently under the scopes every
  /// account already holds, so there is nothing to ask them for.
  Future<bool> hasFullMailAccess(String accountId) async {
    final account = accountById(accountId);
    if (account is! GmailAccount) return false;
    final authService = _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return GmailAuthService.grantsFullMailAccess(token.scope);
  }

  /// Runs the interactive sign-in again for [accountId], this time also asking
  /// for [GmailAuthService.fullMailScope].
  ///
  /// Returns whether the scope came back granted — the user can decline it in
  /// the browser and the flow still "succeeds". Nothing else about the account
  /// changes: the new token lands under the same per-account key, and Google is
  /// told `include_granted_scopes`, so the mail scopes it already had come back
  /// with it. Same shape as [requestCloudDriveAccess]; see that for why neither
  /// scope may be moved into the base set.
  Future<bool> requestFullMailAccess(String accountId) async {
    final account = accountById(accountId);
    if (account == null) throw StateError('Unknown account: $accountId');
    if (account is! GmailAccount) return false;

    final token = await _signInExistingAccount(
      account,
      extraScopes: const [GmailAuthService.fullMailScope],
    );
    // The mail datasource holds a client built around this account's token
    // storage — the key is unchanged, but rebuild for the reason
    // requestCloudDriveAccess does: so the new token is used now rather than
    // after the next refresh.
    if (accountId == activeAccount?.id) _buildDatasourcesForActiveAccount();

    return GmailAuthService.grantsFullMailAccess(token.scope);
  }

  /// Whether [accountId]'s stored token can *write* the mailbox's automatic
  /// reply. Reading it needs nothing extra on either provider.
  ///
  /// Microsoft and Gmail only — IMAP has no such server setting at all, which
  /// the repository reports as an [UnsupportedFailure] rather than as a
  /// missing permission.
  Future<bool> hasOutOfOfficeWriteAccess(String accountId) async {
    // A shared mailbox holds no credentials of its own — its token lives under
    // the signed-in owner's key, and the scope is the owner's to grant. Asking
    // the shared account directly reads no token at all, which would report
    // "permission needed" forever and then re-authenticate the wrong mailbox.
    final account = _credentialOwnerFor(accountById(accountId));
    final authService = account == null
        ? null
        : _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return switch (account) {
      // No incremental consent on a NightMail Server: a token carries every
      // scope the server published, and the Graph `MailboxSettings.ReadWrite`
      // URI is not one it knows. Whether the write works is the server's
      // answer to the save itself.
      MicrosoftAccount(isNightmailServer: true) => true,
      MicrosoftAccount() => MicrosoftAuthService.grantsMailboxSettingsWrite(
        token.scope,
      ),
      GmailAccount() => GmailAuthService.grantsMailSettingsAccess(token.scope),
      _ => false,
    };
  }

  /// The account whose stored credentials [account] actually uses. That is
  /// itself for everything except a shared Microsoft mailbox, which borrows
  /// its parent's — the same resolution [_microsoftAuthConfig] makes when it
  /// picks a token storage key.
  Account? _credentialOwnerFor(Account? account) {
    if (account is MicrosoftAccount && account.parentAccountId != null) {
      return accountById(account.parentAccountId!) ?? account;
    }
    return account;
  }

  /// Runs the interactive sign-in again for [accountId], this time also asking
  /// for the scope that lets the automatic reply be saved.
  ///
  /// Returns whether it came back granted — the user can decline in the
  /// browser and the flow still "succeeds". Nothing else about the account
  /// changes: the new token lands under the same per-account key, Google is
  /// told `include_granted_scopes` and Microsoft re-requests its base set, so
  /// the scopes already held come back with it. Same shape as
  /// [requestFullMailAccess]; see that for why neither may move into the base
  /// scope list.
  Future<bool> requestOutOfOfficeWriteAccess(String accountId) async {
    // Re-authenticate the credential *owner*, not the shared mailbox: the
    // token that needs the extra scope is the owner's, and signing in as a
    // shared mailbox would land a second token under a key nothing reads.
    final account = _credentialOwnerFor(accountById(accountId));
    if (account == null) throw StateError('Unknown account: $accountId');
    // Nothing to ask a NightMail Server for — see hasOutOfOfficeWriteAccess.
    if (account is MicrosoftAccount && account.isNightmailServer) return true;

    final extraScopes = switch (account) {
      MicrosoftAccount() => const [
          MicrosoftAuthService.mailboxSettingsWriteScope,
        ],
      GmailAccount() => const [GmailAuthService.mailSettingsScope],
      ImapAccount() => null,
    };
    if (extraScopes == null) return false;

    final token =
        await _signInExistingAccount(account, extraScopes: extraScopes);
    // The mail datasource holds a client built around this account's token
    // storage — the key is unchanged, but rebuild for the reason
    // requestCloudDriveAccess does: so the new token is used now rather than
    // after the next refresh. Either id can be the active one: the mailbox
    // being edited, or the owner whose token was just replaced.
    final activeId = activeAccount?.id;
    if (accountId == activeId || account.id == activeId) {
      _buildDatasourcesForActiveAccount();
    }

    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService.grantsMailboxSettingsWrite(
        token.scope,
      ),
      GmailAccount() => GmailAuthService.grantsMailSettingsAccess(token.scope),
      ImapAccount() => false,
    };
  }

  /// Whether [accountId]'s stored token can report a message to Microsoft as
  /// phishing (Graph's threat submission API).
  ///
  /// Microsoft only. Gmail has no API for the "Report phishing" its web client
  /// offers and IMAP has nothing of the kind, so for both the report is a plain
  /// move to Junk that needs no scope — the repository never asks for them.
  Future<bool> hasThreatSubmissionAccess(String accountId) async {
    // The owner's token, not the shared mailbox's: see
    // [hasOutOfOfficeWriteAccess] for why asking the shared account directly
    // reads no token at all.
    final account = _credentialOwnerFor(accountById(accountId));
    if (account is! MicrosoftAccount) return false;
    // Microsoft's channel only; a NightMail Server's report is a junk move,
    // see EmailRepositoryImpl.reportPhishing.
    if (account.isNightmailServer) return false;
    final authService = _buildOAuthServiceForAccount(account);
    if (authService == null) return false;
    final token = await authService.getStoredToken();
    if (token == null) return false;
    return MicrosoftAuthService.grantsThreatSubmission(token.scope);
  }

  /// Runs the interactive sign-in again for [accountId], this time also asking
  /// for [MicrosoftAuthService.threatSubmissionScope].
  ///
  /// Returns whether it came back granted — the user can decline in the
  /// browser and the flow still "succeeds". A tenant that reserves the scope
  /// for administrator consent answers the request with an error instead,
  /// which surfaces here as the sign-in's exception; the caller reports it and
  /// the message stays where it was. Nothing else about the account changes:
  /// the new token lands under the same per-account key and Microsoft
  /// re-requests its base set, so the scopes already held come back with it.
  /// Same shape as [requestOutOfOfficeWriteAccess]; see [requestCloudDriveAccess]
  /// for why no incremental scope may move into the base list.
  Future<bool> requestThreatSubmissionAccess(String accountId) async {
    final account = _credentialOwnerFor(accountById(accountId));
    if (account == null) throw StateError('Unknown account: $accountId');
    if (account is! MicrosoftAccount || account.isNightmailServer) return false;

    final token = await _signInExistingAccount(
      account,
      extraScopes: const [MicrosoftAuthService.threatSubmissionScope],
    );
    // Rebuild the active pipeline so the new token is used now rather than
    // after the next refresh — either id can be the active one, the mailbox
    // being read or the owner whose token was just replaced.
    final activeId = activeAccount?.id;
    if (accountId == activeId || account.id == activeId) {
      _buildDatasourcesForActiveAccount();
    }
    return MicrosoftAuthService.grantsThreatSubmission(token.scope);
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
      // A NightMail Server serves its Nextcloud links through the same Graph
      // `/shares` route; one that publishes no file sites has nothing to fetch.
      case MicrosoftAccount(isNightmailServer: true)
          when account.endpoints.filesBaseUrls.isEmpty:
        return null;
      case MicrosoftAccount():
        final cfg = _microsoftAuthConfig(account);
        datasource = GraphDriveDatasourceImpl(
          accountId: account.id,
          provider: account.isNightmailServer
              ? CloudDriveProvider.nextcloud
              : CloudDriveProvider.microsoft,
          client: GraphHttpClient(
            authService: _microsoftAuthServiceFor(cfg),
            onAuthFailure: () =>
                _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () =>
                _authSuccessController.add(cfg.credentialOwnerId),
            baseUrl: cfg.endpoints.graphBaseUrl,
          ),
        );
      case GmailAccount():
        datasource = GoogleDriveDatasourceImpl(
          accountId: account.id,
          client: GoogleDriveHttpClient(
            authService: GmailAuthService(
              clientId: account.clientId ?? AppConfig.gmailClientId,
              clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
              redirectUri: AppConfig.gmailRedirectUri,
              tokenStorage: TokenStorage(
                _secureStorage,
                storageKey: 'token_${account.id}',
              ),
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
    _accounts = await _accountStorage.loadAccounts();
    if (_accounts.isEmpty) {
      await _migrateLegacyAccount();
      _accounts = await _accountStorage.loadAccounts();
    }
    await _migrateSharedClientIdsToAccounts();
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
      final perAccount = TokenStorage(
        _secureStorage,
        storageKey: 'token_${account.id}',
      );
      if (await perAccount.loadToken() != null) return;

      // Per-account token missing — try the old single-account key.
      final legacy = TokenStorage(_secureStorage);
      final token = await legacy.loadToken();
      if (token == null) return;

      await perAccount.saveToken(token);
      await legacy.clearToken();
    } catch (_) {}
  }

  /// One-time migration off the previous design, where Client ID/Secret were
  /// a single value shared across every account of a provider
  /// (`OAuthClientIdStorage`, written by the sign-in dialog and Settings).
  /// That let signing in to, or editing, ANY account silently swap the
  /// credentials every OTHER account's token refresh depended on — see
  /// [MicrosoftAccount.clientId]. Backfills whatever was last saved there
  /// onto every account that predates having its own clientId, then never
  /// needs to touch that legacy storage again for an account once migrated.
  Future<void> _migrateSharedClientIdsToAccounts() async {
    if (_accounts.isEmpty) return;
    final needsMs = _accounts.whereType<MicrosoftAccount>().any(
      (a) => a.clientId == null,
    );
    final needsGoogle = _accounts.whereType<GmailAccount>().any(
      (a) => a.clientId == null,
    );
    if (!needsMs && !needsGoogle) return;

    final legacyMsClientId =
        needsMs ? await _clientIdStorage.loadMicrosoftClientId() : null;
    final legacyGoogleClientId =
        needsGoogle ? await _clientIdStorage.loadGoogleClientId() : null;
    final legacyGoogleClientSecret =
        needsGoogle ? await _clientIdStorage.loadGoogleClientSecret() : null;
    if (legacyMsClientId == null && legacyGoogleClientId == null) return;

    var changed = false;
    final migrated = _accounts.map((a) {
      if (a is MicrosoftAccount && a.clientId == null && legacyMsClientId != null) {
        changed = true;
        return a.copyWith(clientId: legacyMsClientId);
      }
      if (a is GmailAccount && a.clientId == null && legacyGoogleClientId != null) {
        changed = true;
        return a.copyWith(
          clientId: legacyGoogleClientId,
          clientSecret: legacyGoogleClientSecret,
        );
      }
      return a;
    }).toList();

    if (changed) {
      _accounts = migrated;
      await _accountStorage.saveAccounts(_accounts);
    }
  }

  /// Add a new account and make it the active account.
  Future<void> addAccount(Account account) async {
    _accounts = [..._accounts, account];
    _activeIndex = _accounts.length - 1;
    _sortAccounts();
    // Before the awaits — see switchToAccount.
    _buildDatasourcesForActiveAccount();
    await _accountStorage.saveAccounts(_accounts);
    await _accountStorage.saveActiveIndex(_activeIndex);
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
  resolveSharedMailboxCandidate(String parentAccountId, String email) async {
    final ds = directoryDatasourceForAccount(parentAccountId);
    if (ds == null) return null;

    final parent = accountById(parentAccountId);
    final scope = await _storedScope(parentAccountId);
    if (parent is MicrosoftAccount &&
        tokenPredatesSharedMailboxScopes(parent, scope)) {
      return (displayName: email, hasAccess: false, needsReauth: true);
    }

    final profile = await ds.fetchDirectoryProfile(email);
    if (profile == null) return null;
    final displayName = profile.name ?? email;

    final hasAccess = await ds.probeSharedMailboxAccess(email);
    return (displayName: displayName, hasAccess: hasAccess, needsReauth: false);
  }

  /// Whether [owner]'s token [scope] was granted before the `.Shared` scopes
  /// were requested, so no shared mailbox can be reached until it signs in
  /// again — see [resolveSharedMailboxCandidate].
  ///
  /// Never true on a NightMail Server: its token carries only the scopes the
  /// server published (`openid email profile offline_access`), never a Graph
  /// permission URI, and whether the user may open a shared mailbox is the
  /// server's own answer to the probe (its members-only `/users/{address}`,
  /// ADR 0004 D4 in nightware). Asking for `Mail.Read.Shared` there would send
  /// the user to re-authenticate forever, since no sign-in can add it.
  static bool tokenPredatesSharedMailboxScopes(
    MicrosoftAccount owner,
    String? scope,
  ) =>
      !owner.isNightmailServer &&
      scope != null &&
      !scope.contains('Mail.Read.Shared');

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
      clientId: parent.clientId,
      parentAccountId: parentAccountId,
      server: parent.server,
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

    // Before the awaits — see switchToAccount.
    if (activeAccount?.id == updatedAccount.id) {
      _buildDatasourcesForActiveAccount();
    }

    await _accountStorage.saveAccounts(_accounts);
    await _accountStorage.saveActiveIndex(_activeIndex);
  }

  /// Cycle to the next account. Returns the newly active account.
  Future<Account> cycleToNextAccount() async {
    if (_accounts.length < 2) {
      throw StateError('Need at least 2 accounts to cycle');
    }
    _activeIndex = (_activeIndex + 1) % _accounts.length;
    // Before the await — see switchToAccount.
    _buildDatasourcesForActiveAccount();
    await _accountStorage.saveActiveIndex(_activeIndex);
    return _accounts[_activeIndex];
  }

  /// Switch to a specific account by index.
  ///
  /// The datasources are rebuilt *before* the index is persisted, and the same
  /// order holds in [addAccount], [updateAccount] and [cycleToNextAccount].
  /// `EmailRepositoryImpl` guards against a switch landing mid-fetch by reading
  /// [activeAccount] and [emailDatasource] together, before its first await —
  /// a guard that only works if the two can never disagree. With the storage
  /// write awaited in between, they did: for the length of a Keychain write
  /// [activeAccount] was already the new account while [emailDatasource] still
  /// answered for the old one, and a fetch starting in that window bound the
  /// new account's id to the old mailbox's data (observed: Graph messages
  /// filed under a Gmail account's cache in the same second as that account's
  /// own listing landed).
  Future<void> switchToAccount(int index) async {
    if (index < 0 || index >= _accounts.length) {
      throw RangeError.index(index, _accounts);
    }
    _activeIndex = index;
    _buildDatasourcesForActiveAccount();
    await _accountStorage.saveActiveIndex(_activeIndex);
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
    _labelCountMemos.remove(accountId);
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
    final account = activeAccount;
    if (account == null) throw StateError('No active account');
    await reauthenticateOAuthAccount(account.id);
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
  /// locked-out one. A sign-in that comes back as a *different* mailbox is
  /// refused before anything is stored — see [_signInExistingAccount].
  Future<void> reauthenticateOAuthAccount(String accountId) async {
    final account = accountById(accountId);
    if (account == null) throw StateError('Unknown account: $accountId');

    // A shared mailbox has no credentials of its own to renew — the token
    // that needs refreshing belongs to whichever account it rides on.
    if (account is MicrosoftAccount && account.parentAccountId != null) {
      return reauthenticateOAuthAccount(account.parentAccountId!);
    }

    await _signInExistingAccount(account);

    // The new token lands under the same per-account storage key, so existing
    // datasources would pick it up anyway; rebuilding the active account's
    // pipeline just avoids waiting on a refresh cycle to notice.
    if (accountId == activeAccount?.id) _buildDatasourcesForActiveAccount();
  }

  /// The OAuth service for [account], or null for account types that do not use
  /// OAuth (IMAP, which authenticates with a stored password).
  AuthService? _buildOAuthServiceForAccount(
    Account account, {
    List<String> extraScopes = const [],
    SignInVerifier? verifySignIn,
  }) {
    final tokenStorage = TokenStorage(
      _secureStorage,
      storageKey: 'token_${account.id}',
    );
    return switch (account) {
      MicrosoftAccount() => MicrosoftAuthService(
        clientId: account.clientId ?? AppConfig.microsoftClientId,
        tenantId: account.tenantId,
        redirectUri: AppConfig.microsoftRedirectUri,
        tokenStorage: tokenStorage,
        extraScopes: extraScopes,
        verifySignIn: verifySignIn,
        endpoints: account.endpoints,
      ),
      // The email is what lets a Workspace account pick up the room-directory
      // scope on re-auth; see GmailAuthService._requestedScopes.
      GmailAccount() => GmailAuthService(
        clientId: account.clientId ?? AppConfig.gmailClientId,
        clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
        redirectUri: AppConfig.gmailRedirectUri,
        tokenStorage: tokenStorage,
        accountEmail: account.emailAddress,
        extraScopes: extraScopes,
        verifySignIn: verifySignIn,
      ),
      ImapAccount() => null,
    };
  }

  /// The interactive sign-in for an account that already exists, keeping the
  /// token only if the mailbox that signed in is [account]'s. Every re-sign-in
  /// and every incremental-scope flow comes through here, and every one of
  /// them leaves the account knowing the addresses its mailbox answers for.
  ///
  /// Google's `login_hint` (and Microsoft's account picker) only *suggest* an
  /// account. After a forced password reset the browser's session for this
  /// account is gone, and the one still signed in there is routinely another
  /// of the user's accounts — which Google then shows a consent screen for as
  /// if nothing were amiss. Without this check that account's token landed
  /// under this account's key, and this account showed the other mailbox's
  /// folders and mail.
  ///
  /// The check runs inside the auth service, *before* the token is stored, so
  /// a refused token is never on disk — not even for the moment it would take
  /// to put the old one back, during which a poll could have fetched the wrong
  /// mailbox into this account's cache. An account recorded without an address
  /// (every Gmail account added before addresses were learned on add) adopts
  /// the one that signed in, which is also what gives its next sign-in a
  /// `login_hint`; and every account keeps the aliases the provider lists
  /// alongside it, which a reply-all strips from its recipients — see
  /// [Account.aliases].
  Future<AuthToken> _signInExistingAccount(
    Account account, {
    List<String> extraScopes = const [],
  }) async {
    final SignedInMailboxLookup? lookup = switch (account) {
      MicrosoftAccount() =>
        GraphMailboxLookup(graphBaseUrl: account.endpoints.graphBaseUrl),
      GmailAccount() => GmailMailboxLookup(),
      ImapAccount() => null,
    };
    List<String>? learned;
    final authService = lookup == null
        ? null
        : _buildOAuthServiceForAccount(
            account,
            extraScopes: extraScopes,
            verifySignIn: mailboxGuard(
              accountEmail: account.emailAddress,
              lookup: lookup,
              onAddressesLearned: (addresses) => learned = addresses,
            ),
          );
    if (authService == null) {
      throw StateError('${account.emailAddress} does not sign in with OAuth');
    }

    final token = await authService.signIn();
    final addresses = learned;
    if (addresses != null) {
      // Re-read: the browser round trip is long enough for Settings to have
      // saved an edit this must not clobber.
      final current = accountById(account.id) ?? account;
      final updated = current.withMailboxAddresses(addresses);
      if (updated != current) await updateAccount(updated);
    }
    // The stored token is this account's and works: say so, the same way the
    // interceptor does after a refresh, so every "needs re-authentication"
    // flag clears now rather than at whatever next checks it.
    _authSuccessController.add(account.id);
    return token;
  }

  /// Re-authenticate an IMAP account by saving the supplied password.
  Future<void> reauthenticateImapAccount(
    String accountId,
    String password,
  ) async {
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
        return GraphApiDatasourceImpl(
          mailboxAddress: cfg.mailboxAddress,
          betaBaseUrl: cfg.endpoints.graphBetaBaseUrl,
          client: _graphClientFor(account),
        );

      case GmailAccount():
        return GmailDatasourceImpl(
          client: _gmailClientFor(account),
          displayName: account.senderName,
          accountEmail: account.emailAddress,
          labelCounts: _labelCountMemos.putIfAbsent(
              account.id, GmailLabelCountMemo.new),
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

  /// Where [account]'s change stream is (nightware ADR 0007), or null when it
  /// has none: not a Graph account, or its server publishes no `changesUrl`.
  /// A shared mailbox watches its own address through its owner's server and
  /// token — the same resolution every Graph call it makes goes through.
  ChangeStreamTarget? changeStreamTargetFor(Account account) {
    if (account is! MicrosoftAccount) return null;
    final url = _microsoftAuthConfig(account).endpoints.changesUrl;
    if (url == null) return null;
    return (
      url: url,
      mailbox: account.parentAccountId != null ? account.emailAddress : null,
    );
  }

  /// One connection to [account]'s change stream, on a Graph client of its own
  /// so the bearer token, its refresh and a 401's re-auth flag are exactly
  /// those of the account's other calls. Errors at once when the account has
  /// no stream ([changeStreamTargetFor]).
  Stream<ChangeStreamEvent> openChangeStream(Account account) {
    final target = changeStreamTargetFor(account);
    if (target == null || account is! MicrosoftAccount) {
      return Stream.error(
          StateError('${account.id} has no change stream to open'));
    }
    return ChangeStreamDatasource(_graphClientFor(account).dio)
        .open(target.url, mailbox: target.mailbox);
  }

  /// A Graph client authenticating as [account] — with the parent's
  /// credentials for a shared mailbox, see [_microsoftAuthConfig]. A fresh
  /// one each call: it is stateless, unlike the IMAP datasource.
  GraphHttpClient _graphClientFor(MicrosoftAccount account) {
    final cfg = _microsoftAuthConfig(account);
    final authSvc = _microsoftAuthServiceFor(cfg);
    return GraphHttpClient(
      authService: authSvc,
      onAuthFailure: () => _authFailureController.add(cfg.credentialOwnerId),
      onAuthSuccess: () => _authSuccessController.add(cfg.credentialOwnerId),
      baseUrl: cfg.endpoints.graphBaseUrl,
    );
  }

  /// The auth service behind every Graph client for a resolved
  /// [_microsoftAuthConfig]: the account's client id, tenant and endpoints —
  /// Microsoft's, or its NightMail Server's.
  MicrosoftAuthService _microsoftAuthServiceFor(
    ({
      TokenStorage tokenStorage,
      String tenantId,
      String? clientId,
      GraphEndpoints endpoints,
      String credentialOwnerId,
      String? mailboxAddress,
    }) cfg,
  ) =>
      MicrosoftAuthService(
        clientId: cfg.clientId ?? AppConfig.microsoftClientId,
        tenantId: cfg.tenantId,
        redirectUri: AppConfig.microsoftRedirectUri,
        tokenStorage: cfg.tokenStorage,
        endpoints: cfg.endpoints,
      );

  /// A Gmail client authenticating as [account]; likewise stateless.
  GmailHttpClient _gmailClientFor(GmailAccount account) {
    final tokenStorage = TokenStorage(
      _secureStorage,
      storageKey: 'token_${account.id}',
    );
    final authSvc = GmailAuthService(
      clientId: account.clientId ?? AppConfig.gmailClientId,
      clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
      redirectUri: AppConfig.gmailRedirectUri,
      tokenStorage: tokenStorage,
      accountEmail: account.emailAddress,
    );
    return GmailHttpClient(
      authService: authSvc,
      onAuthFailure: () => _authFailureController.add(account.id),
      onAuthSuccess: () => _authSuccessController.add(account.id),
    );
  }

  /// Learns, for every OAuth account that does not yet know them, the
  /// addresses its mailbox receives mail at — see [Account.aliases]: the
  /// primary address for an account recorded without one (a legacy-migrated
  /// Microsoft account, or a Gmail account added before 1.37.4 started
  /// learning it on add) and the provider's aliases for any account never
  /// asked. They are what a reply-all strips from its recipients, so an
  /// account missing them kept putting the user in their own Reply All —
  /// on a phone that never re-signed in, long after the desktop had.
  ///
  /// Best-effort and silent: a failed or empty lookup leaves the account as
  /// it was, to be asked again at the next launch. Runs after the loaded
  /// state is emitted (see AccountCubit) so a slow network never holds up
  /// startup. IMAP accounts have no provider to ask, and a shared mailbox's
  /// credentials answer for its owner, so both are left alone. Also called
  /// from secondary windows, which load the stored accounts on their own.
  Future<void> ensureEmailPopulated() async {
    for (final account in List<Account>.of(_accounts)) {
      if (!_lacksMailboxAddresses(account)) continue;
      List<String> addresses;
      try {
        addresses = await _mailboxAddressesOf(account);
      } catch (_) {
        continue;
      }
      // Re-read: the lookup was a network round trip, during which Settings
      // may have saved an edit this must not clobber.
      final current = accountById(account.id);
      if (current == null) continue;
      final updated = current.withMailboxAddresses(addresses);
      if (updated != current) await updateAccount(updated);
    }
  }

  /// Asks each NightMail Server the accounts live on — or just [serverUrl] —
  /// for its discovery document again and adopts the file sites it now
  /// publishes. Discovery is otherwise only read when an account is added, so
  /// without this a server that starts publishing `filesBaseUrls` — or an
  /// account added before servers could — never turns on Nextcloud link
  /// previews.
  ///
  /// Returns one outcome per server, each logged: every way this can leave
  /// previews off used to end in a bare `continue`, and on 2026-11-19 that
  /// left a link previewing nothing with no record of which one it was.
  Future<List<FileSitesRefresh>> refreshServerFileSites(
    Future<Either<Failure, GraphEndpoints>> Function(String serverUrl)
        discover, {
    String? serverUrl,
  }) async {
    final serverUrls = {
      for (final account in _accounts)
        if (account case MicrosoftAccount(:final server?)
            when server.serverUrl != null &&
                (serverUrl == null || server.serverUrl == serverUrl))
          server.serverUrl!,
    };
    final outcomes = <FileSitesRefresh>[];
    for (final url in serverUrls) {
      final outcome = await _refreshFileSites(url, discover);
      debugPrint('[FileSites] $url: ${_describe(outcome)}'
          '${outcome.previewsOff ? ' — document previews are off' : ''}');
      outcomes.add(outcome);
    }
    return outcomes;
  }

  Future<FileSitesRefresh> _refreshFileSites(
    String serverUrl,
    Future<Either<Failure, GraphEndpoints>> Function(String serverUrl)
        discover,
  ) async {
    final Either<Failure, GraphEndpoints> answer;
    try {
      answer = await discover(serverUrl);
    } catch (e) {
      return FileSitesUnreachable(serverUrl,
          reason: '$e', previewsOff: _serverPreviewsOff(serverUrl));
    }
    final rediscovered = answer.toNullable();
    if (rediscovered == null) {
      return FileSitesUnreachable(serverUrl,
          reason: answer.getLeft().toNullable()!.message,
          previewsOff: _serverPreviewsOff(serverUrl));
    }

    // Re-read after the round trip, as ensureEmailPopulated does: shared
    // mailboxes carry their parent's copy and are refreshed with it.
    var updatedAny = false;
    for (final account in List<Account>.of(_accounts)) {
      if (account is! MicrosoftAccount ||
          account.server?.serverUrl != serverUrl) {
        continue;
      }
      final changed = account.server!.signInChangeFrom(rediscovered);
      if (changed != null) {
        return FileSitesRefused(serverUrl,
            changed: changed, previewsOff: _serverPreviewsOff(serverUrl));
      }
      final updated = account.withRediscoveredServer(rediscovered);
      if (identical(updated, account)) continue;
      _driveDatasourceCache.remove(account.id);
      await updateAccount(updated);
      updatedAny = true;
    }
    final previewsOff = _serverPreviewsOff(serverUrl);
    return updatedAny
        ? FileSitesUpdated(serverUrl, previewsOff: previewsOff)
        : FileSitesUnchanged(serverUrl, previewsOff: previewsOff);
  }

  bool _serverPreviewsOff(String serverUrl) => !_accounts.any((a) =>
      a is MicrosoftAccount &&
      a.server?.serverUrl == serverUrl &&
      a.endpoints.filesBaseUrls.isNotEmpty);

  static String _describe(FileSitesRefresh outcome) => switch (outcome) {
        FileSitesUpdated() => 'adopted the file sites it publishes',
        FileSitesUnchanged() => 'file sites unchanged',
        FileSitesUnreachable(:final reason) => 'unreachable: $reason',
        FileSitesRefused(:final changed) =>
          'not adopted — its $changed changed, which needs the account re-added',
      };

  /// Whether a NightMail Server account lives at [host] while holding no file
  /// sites — when a link there is most likely its Nextcloud, unrecognised
  /// because the refresh that would have taught the scanner the host has not
  /// succeeded. Returns that server's address, or null.
  String? serverWithoutFileSitesAt(String host) {
    for (final account in _accounts) {
      if (account case MicrosoftAccount(:final server?)
          when server.serverUrl != null &&
              server.filesBaseUrls.isEmpty &&
              _hostOf(server.serverUrl!) == host.toLowerCase()) {
        return server.serverUrl;
      }
    }
    return null;
  }

  /// The host of a server address, which is stored as the reader typed it —
  /// possibly without a scheme.
  static String? _hostOf(String serverUrl) {
    final withScheme =
        serverUrl.contains('://') ? serverUrl : 'https://$serverUrl';
    final host = Uri.tryParse(withScheme)?.host.toLowerCase();
    return host == null || host.isEmpty ? null : host;
  }

  static bool _lacksMailboxAddresses(Account account) => switch (account) {
        ImapAccount() => false,
        MicrosoftAccount(isSharedMailbox: true) => false,
        _ => account.emailAddress.trim().isEmpty || account.aliases == null,
      };

  Future<List<String>> _mailboxAddressesOf(Account account) {
    final override = _mailboxAddressesOverride;
    if (override != null) return override(account);
    return switch (account) {
      MicrosoftAccount() => GraphMailboxLookup(
          graphBaseUrl: _microsoftAuthConfig(account).endpoints.graphBaseUrl,
        ).addressesWith(_graphClientFor(account).dio),
      GmailAccount() =>
        GmailMailboxLookup().addressesWith(_gmailClientFor(account).dio),
      ImapAccount() => Future.value(const []),
    };
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
        final authSvc = _microsoftAuthServiceFor(cfg);
        final httpClient = GraphHttpClient(
          authService: authSvc,
          onAuthFailure: () =>
              _authFailureController.add(cfg.credentialOwnerId),
          onAuthSuccess: () =>
              _authSuccessController.add(cfg.credentialOwnerId),
          baseUrl: cfg.endpoints.graphBaseUrl,
        );
        final ds = GraphApiDatasourceImpl(
          betaBaseUrl: cfg.endpoints.graphBetaBaseUrl,
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
          clientId: account.clientId ?? AppConfig.gmailClientId,
          clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
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
          accountEmail: account.emailAddress,
          labelCounts: _labelCountMemos.putIfAbsent(
              account.id, GmailLabelCountMemo.new),
        );
        _calendarDatasource = GoogleCalendarDatasourceImpl(
          client: calendarClient,
          accountEmail: account.emailAddress,
        );
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
        final authSvc = _microsoftAuthServiceFor(cfg);
        return GraphApiDatasourceImpl(
          betaBaseUrl: cfg.endpoints.graphBetaBaseUrl,
          mailboxAddress: cfg.mailboxAddress,
          client: GraphHttpClient(
            authService: authSvc,
            onAuthFailure: () =>
                _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () =>
                _authSuccessController.add(cfg.credentialOwnerId),
            baseUrl: cfg.endpoints.graphBaseUrl,
          ),
        );
      case GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = GmailAuthService(
          clientId: account.clientId ?? AppConfig.gmailClientId,
          clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
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
          accountEmail: account.emailAddress,
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
        final authSvc = _microsoftAuthServiceFor(cfg);
        return GraphApiDatasourceImpl(
          betaBaseUrl: cfg.endpoints.graphBetaBaseUrl,
          mailboxAddress: cfg.mailboxAddress,
          client: GraphHttpClient(
            authService: authSvc,
            onAuthFailure: () =>
                _authFailureController.add(cfg.credentialOwnerId),
            onAuthSuccess: () =>
                _authSuccessController.add(cfg.credentialOwnerId),
            baseUrl: cfg.endpoints.graphBaseUrl,
          ),
        );
      case GmailAccount():
        final tokenStorage = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
        final authSvc = GmailAuthService(
          clientId: account.clientId ?? AppConfig.gmailClientId,
          clientSecret: account.clientSecret ?? AppConfig.gmailClientSecret,
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
        final ts = TokenStorage(
          _secureStorage,
          storageKey: 'token_${account.id}',
        );
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
