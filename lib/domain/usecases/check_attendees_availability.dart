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
    );
  }
}

class CheckAttendeesAvailabilityParams {
  const CheckAttendeesAvailabilityParams({
    required this.emails,
    required this.start,
    required this.end,
    this.organizerEmail,
  });

  final List<String> emails;
  final DateTime start;
  final DateTime end;
  final String? organizerEmail;
}
