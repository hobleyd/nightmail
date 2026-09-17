import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/out_of_office_settings.dart';
import '../../domain/repositories/out_of_office_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/network/connectivity_service.dart';
import '../datasources/remote/out_of_office_datasource.dart';

class OutOfOfficeRepositoryImpl implements OutOfOfficeRepository {
  OutOfOfficeRepositoryImpl({
    required AccountManager accountManager,
    required ConnectivityService connectivityService,
  })  : _accountManager = accountManager,
        _connectivityService = connectivityService;

  final AccountManager _accountManager;
  final ConnectivityService _connectivityService;

  @override
  Future<Either<Failure, OutOfOfficeSettings>> getOutOfOffice(
    String accountId,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! OutOfOfficeDatasource) return Left(_unsupported(accountId));
    return _execute(() => datasource.getOutOfOffice());
  }

  @override
  Future<Either<Failure, Unit>> setOutOfOffice(
    String accountId,
    OutOfOfficeSettings settings,
  ) async {
    final datasource = _datasourceFor(accountId);
    if (datasource is! OutOfOfficeDatasource) return Left(_unsupported(accountId));
    return _execute(() async {
      await datasource.setOutOfOffice(settings);
      return unit;
    });
  }

  /// Resolves [accountId] to something that might speak out-of-office.
  ///
  /// Returns null — rather than falling back to the active account the way
  /// `EmailRepositoryImpl._datasourceFor` does — when the id names no
  /// configured account. There the fallback is a convenience; here it would
  /// write one mailbox's away message onto another's.
  Object? _datasourceFor(String accountId) {
    final account = _accountManager.accounts
        .cast<Account?>()
        .firstWhere((a) => a?.id == accountId, orElse: () => null);
    if (account == null) return null;
    if (accountId == _accountManager.activeAccount?.id) {
      return _accountManager.emailDatasource;
    }
    return _accountManager.buildEmailDatasourceForAccount(account);
  }

  Failure _unsupported(String accountId) {
    final account = _accountManager.accounts
        .cast<Account?>()
        .firstWhere((a) => a?.id == accountId, orElse: () => null);
    if (account == null) {
      return const UnsupportedFailure(message: 'That account is not signed in.');
    }
    // A shared Microsoft mailbox reaches the datasource — its path is
    // `/users/{address}/mailboxSettings`, which Graph does expose — so it is
    // not refused here. If the tenant declines it the save fails with Graph's
    // own message; there is no `MailboxSettings.*.Shared` delegated permission
    // to check for in advance.
    return const UnsupportedFailure(
      message: 'Out of office replies are not available for this account type.',
    );
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
