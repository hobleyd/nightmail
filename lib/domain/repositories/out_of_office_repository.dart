import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/out_of_office_settings.dart';

/// Reads and writes one account's out-of-office (automatic reply) setting.
///
/// Account-scoped rather than "the active account", because the Out of Office
/// screen edits whichever mailbox the user picked from its own list — a screen
/// that silently edited only the active account would be a trap on a machine
/// with several signed in.
///
/// An account whose provider has no such setting (IMAP) answers
/// [UnsupportedFailure], which the screen reports as "not available for this
/// account" rather than as something that went wrong.
abstract interface class OutOfOfficeRepository {
  Future<Either<Failure, OutOfOfficeSettings>> getOutOfOffice(String accountId);

  Future<Either<Failure, Unit>> setOutOfOffice(
    String accountId,
    OutOfOfficeSettings settings,
  );
}
