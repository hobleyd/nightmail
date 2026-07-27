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
      excludeEventId: params.excludeEventId,
      excludeStart: params.excludeStart,
      excludeEnd: params.excludeEnd,
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
    this.excludeEventId,
    this.excludeStart,
    this.excludeEnd,
  });

  final List<String> emails;
  final DateTime start;
  final DateTime end;
  final String? organizerEmail;

  /// The meeting being edited, which must not clash with itself. Null when
  /// composing a new meeting — there is nothing on anyone's calendar yet.
  final String? excludeEventId;

  /// The excluded meeting's stored slot, used to discount each guest's copy of
  /// it. Free/busy responses carry no event id, so this is the only handle on
  /// it for anyone other than the organizer.
  final DateTime? excludeStart;
  final DateTime? excludeEnd;

  /// The account whose calendar should answer the query — the account the
  /// meeting is being created on, which is not necessarily the active one.
  /// Null falls back to the active account.
  final String? accountId;
}
