import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/entities/mail_rule.dart';
import '../../domain/repositories/mail_rules_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/network/connectivity_service.dart';
import '../datasources/local/folder_local_datasource.dart';
import '../datasources/local/local_mail_rules_datasource.dart';
import '../datasources/local/mail_rule_store.dart';
import '../datasources/remote/email_remote_datasource.dart';
import '../datasources/remote/mail_rule_codecs.dart';
import '../datasources/remote/mail_rules_datasource.dart';

class MailRulesRepositoryImpl implements MailRulesRepository {
  MailRulesRepositoryImpl({
    required this._accountManager,
    required this._connectivityService,
    required this._folderLocalDatasource,
    required this._mailRuleStore,
  });

  final AccountManager _accountManager;
  final ConnectivityService _connectivityService;
  final FolderLocalDatasource _folderLocalDatasource;
  final MailRuleStore _mailRuleStore;

  @override
  Future<Either<Failure, MailRuleSet>> getMailRules(String accountId) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! MailRulesDatasource) return Left(_unsupported(accountId));
    final result = await _run(
      datasource,
      () async => MailRuleSet(
        rules: await datasource.getMailRules(),
        capabilities: datasource.mailRuleCapabilities,
      ),
    );
    // Nightware is still bringing up its Graph surface, and a server without
    // `messageRules` yet answers 404 or 501. That is "not here yet", which
    // the screen shows as a notice — not an error with a retry button that
    // can never succeed.
    return result.mapLeft((failure) {
      final account = _accountById(accountId);
      if (account is MicrosoftAccount &&
          account.isNightmailServer &&
          failure is ServerFailure &&
          (failure.statusCode == 404 || failure.statusCode == 501)) {
        return const UnsupportedFailure(
          message: 'Rules are not available on this NightMail Server yet.',
        );
      }
      return failure;
    });
  }

  @override
  Future<Either<Failure, List<EmailFolder>>> getMailRuleFolders(
    String accountId,
  ) async {
    try {
      var folders = await _folderLocalDatasource.getCachedFolders(accountId);
      if (folders.isEmpty) {
        // An account added but never opened has nothing cached yet.
        final datasource = _datasourceFor(accountId);
        if (datasource is EmailRemoteDatasource &&
            await _connectivityService.isOnline) {
          folders = await _walkFolders(datasource);
        }
      }
      final account = _accountById(accountId);
      return Right(
        _targets(
          folders,
          gmail: account is GmailAccount,
          imap: account is ImapAccount,
        ),
      );
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }

  /// The folders a rule can file into, each named by its full path
  /// ("Clients/Acme") — a picker of leaf names cannot tell two "Archive"
  /// folders apart — and sorted by it.
  ///
  /// Gmail's `__virtual__` parents stand in for a "/" path segment with no
  /// label of its own, so they name the path but cannot be chosen; SPAMDB is
  /// the app's own spam-database folder. On Gmail only user labels are
  /// targets: INBOX, SENT, TRASH and the rest are either refused by Gmail or
  /// read back as a different action (TRASH as delete), which would leave
  /// the filter view-only the moment it was saved.
  ///
  /// On IMAP the Inbox is left out: NightMail runs those rules on new Inbox
  /// mail, and a copy into it would arrive as new mail and be copied again,
  /// every cycle, without end.
  static List<EmailFolder> _targets(
    List<EmailFolder> folders, {
    required bool gmail,
    required bool imap,
  }) {
    final byId = {for (final f in folders) f.id: f};
    String path(EmailFolder f) {
      final parts = <String>[f.displayName];
      final seen = {f.id};
      var parent = f.parentFolderId;
      while (parent != null && seen.add(parent)) {
        final p = byId[parent];
        if (p == null) break;
        parts.insert(0, p.displayName);
        parent = p.parentFolderId;
      }
      return parts.join('/');
    }

    return [
      for (final f in folders)
        if (!f.id.startsWith('__virtual__') &&
            f.displayName.toLowerCase() != 'spamdb' &&
            (!gmail || GmailFilterCodec.isUserLabel(f.id)) &&
            !(imap && f.id.toUpperCase() == 'INBOX'))
          f.copyWith(displayName: path(f)),
    ]..sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
  }

  /// The same breadth-first walk as `EmailRepositoryImpl.getMailFolders`,
  /// without writing the cache — that belongs to the mail list's own load.
  Future<List<EmailFolder>> _walkFolders(EmailRemoteDatasource remote) async {
    final all = <EmailFolder>[...await remote.getMailFolders()];
    var toExpand = all.where((f) => f.childFolderCount > 0).toList();
    while (toExpand.isNotEmpty) {
      final children = (await Future.wait(
        toExpand.map((f) => remote.getChildFolders(f.id)),
      )).expand((c) => c).toList();
      all.addAll(children);
      toExpand = children.where((f) => f.childFolderCount > 0).toList();
    }
    return all;
  }

  @override
  Future<Either<Failure, Unit>> saveMailRule(
    String accountId,
    MailRule rule,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! MailRulesDatasource) return Left(_unsupported(accountId));
    return _run(datasource, () async {
      if (rule.id == null) {
        await datasource.createMailRule(rule);
      } else {
        await datasource.updateMailRule(rule);
      }
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> deleteMailRule(
    String accountId,
    String ruleId,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! MailRulesDatasource) return Left(_unsupported(accountId));
    return _run(datasource, () async {
      await datasource.deleteMailRule(ruleId);
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> setMailRuleEnabled(
    String accountId,
    String ruleId,
    bool enabled,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! MailRulesDatasource) return Left(_unsupported(accountId));
    return _run(datasource, () async {
      await datasource.setMailRuleEnabled(ruleId, enabled);
      return unit;
    });
  }

  @override
  Future<Either<Failure, Unit>> reorderMailRules(
    String accountId,
    Map<String, int> sequences,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! MailRulesDatasource) return Left(_unsupported(accountId));
    return _run(datasource, () async {
      await datasource.reorderMailRules(sequences);
      return unit;
    });
  }

  Account? _accountById(String accountId) => _accountManager.accounts
      .cast<Account?>()
      .firstWhere((a) => a?.id == accountId, orElse: () => null);

  /// Resolves [accountId] to its datasource, or null when the id names no
  /// configured account — never the active account as a fallback, for the
  /// reason `OutOfOfficeRepositoryImpl._datasourceFor` gives: a rule written
  /// to the wrong mailbox acts on somebody else's mail.
  Object? _datasourceFor(String accountId) {
    final account = _accountById(accountId);
    if (account == null) return null;
    // IMAP has no rules API this app speaks, so its rules are NightMail's
    // own, run by LocalMailRuleRunner on new Inbox mail.
    if (account is ImapAccount) {
      return LocalMailRulesDatasource(
        store: _mailRuleStore,
        accountId: accountId,
      );
    }
    if (accountId == _accountManager.activeAccount?.id) {
      return _accountManager.emailDatasource;
    }
    return _accountManager.buildEmailDatasourceForAccount(account);
  }

  Failure _unsupported(String accountId) {
    if (_accountById(accountId) == null) {
      return const UnsupportedFailure(message: 'That account is not signed in.');
    }
    return const UnsupportedFailure(
      message: 'Rules are not available for this account type.',
    );
  }

  /// Server rules go through [_execute]; local ones are files on this
  /// device, which need no network and whose failures are not auth failures
  /// (`_execute` reads a StateError as one).
  Future<Either<Failure, T>> _run<T>(
    MailRulesDatasource datasource,
    Future<T> Function() fn,
  ) async {
    if (datasource.mailRuleCapabilities.runsOnServer) return _execute(fn);
    try {
      return Right(await fn());
    } on StateError catch (e) {
      return Left(CacheFailure(message: e.message));
    } catch (e) {
      return Left(CacheFailure(message: 'Could not save the rules: $e'));
    }
  }

  /// Same exception→Failure mapping as every other repository here. Duplicated
  /// rather than shared, which is the house style.
  Future<Either<Failure, T>> _execute<T>(Future<T> Function() fn) async {
    if (!await _connectivityService.isOnline) {
      return const Left(NetworkFailure(message: 'No network connection'));
    }
    try {
      return Right(await fn());
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } on StateError catch (e) {
      return Left(AuthFailure(message: e.message));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
