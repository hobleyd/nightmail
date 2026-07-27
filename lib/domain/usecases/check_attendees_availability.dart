import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/attendee_availability.dart';
import '../repositories/calendar_repository.dart';

class CheckAttendeesAvailability
    implements
        UseCase<List<AttendeeAvailability>, CheckAttendeesAvailabilityParams> {
  const CheckAttendeesAvailability(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, List<AttendeeAvailability>>> call(
      CheckAttendeesAvailabilityParams params) {
    return _repository.checkAttendeesAvailability(
      emails: params.emails,
      start: params.start,
      end: params.end,
      organizerEmail: params.organizerEmail,
      accountId: params.accountId,
    );
  }
}

class CheckAttendeesAvailabilityParams {
  const CheckAttendeesAvailabilityParams({
    required this.emails,
    required this.start,
    required this.end,
    this.organizerEmail,
    this.accountId,
  });

  final List<String> emails;
  final DateTime start;
  final DateTime end;
  final String? organizerEmail;

  /// The account whose calendar should answer the query — the account the
  /// meeting is being created on, which is not necessarily the active one.
  /// Null falls back to the active account.
  final String? accountId;
}
