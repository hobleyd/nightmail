import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/cloud_document.dart';
import '../../domain/repositories/cloud_drive_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';

/// Fetches a linked cloud document with whichever signed-in account can reach
/// it.
///
/// The account is chosen by the *link*, not by the mailbox the mail arrived in:
/// a OneDrive link in Gmail is fetched by a Microsoft account, and a Drive link
/// in Exchange by a Gmail one. With several accounts of the same provider — two
/// tenants, work and personal — they are tried in turn, because only one of
/// them may have been shared the file.
class CloudDriveRepositoryImpl implements CloudDriveRepository {
  const CloudDriveRepositoryImpl({required AccountManager accountManager})
      : _accountManager = accountManager;

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, CloudDocument>> fetchDocument(
      CloudDocumentLink link) async {
    final candidates = _accountManager.cloudDriveCandidates(link.provider);
    if (candidates.isEmpty) {
      return Left(CloudDriveUnavailable(
          message: 'No ${_providerName(link.provider)} account is signed in'));
    }

    // Split by whether file access has been granted rather than filtering: an
    // account that has not been asked yet is the fallback offer if every
    // account that *has* been asked turns out not to be able to see the file.
    final granted = <String>[];
    final notGranted = <String>[];
    for (final account in candidates) {
      if (await _accountManager.hasCloudDriveAccess(account.id)) {
        granted.add(account.id);
      } else {
        notGranted.add(account.id);
      }
    }

    Failure? lastFailure;
    for (final accountId in granted) {
      final datasource =
          _accountManager.cloudDriveDatasourceForAccount(accountId);
      if (datasource == null) continue;
      try {
        return Right(await datasource.fetchDocument(link));
      } on NetworkException catch (e) {
        // Stop here. Trying every remaining account would report "cannot
        // preview this link" to a reader who is simply offline — the same
        // distinction AuthInterceptor goes out of its way to keep.
        return Left(NetworkFailure(message: e.message));
      } on CloudDocumentNotPreviewableException catch (e) {
        // A settled answer about the document itself, not about this account.
        return Left(CloudDriveUnavailable(message: e.message));
      } on AuthException catch (e) {
        lastFailure = AuthFailure(message: e.message);
      } on ServerException catch (e) {
        // 403/404 means *this* account cannot see the file: someone else's
        // tenant, or a file shared with another address. Any other status is
        // the provider having a bad day and says nothing about the next
        // account, so it is reported as it stands.
        if (e.statusCode != 403 && e.statusCode != 404) {
          return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
        }
        lastFailure = ServerFailure(message: e.message, statusCode: e.statusCode);
      }
    }

    // Nothing granted could fetch it. If an account has never been asked for
    // access, that is the one to offer — including the case where none has.
    if (notGranted.isNotEmpty) {
      final account = _accountManager.accountById(notGranted.first);
      if (account != null) {
        return Left(CloudDriveAccessNotGranted(
          message:
              'NightMail needs permission to read ${_providerName(link.provider)} files',
          accountId: account.id,
          accountEmail: account.emailAddress,
        ));
      }
    }

    return Left(lastFailure ??
        CloudDriveUnavailable(
            message:
                'None of your ${_providerName(link.provider)} accounts can open that document'));
  }

  String _providerName(CloudDriveProvider provider) => switch (provider) {
        CloudDriveProvider.microsoft => 'Microsoft 365',
        CloudDriveProvider.google => 'Google',
      };
}
