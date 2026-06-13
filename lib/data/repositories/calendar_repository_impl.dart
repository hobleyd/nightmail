import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/repositories/calendar_repository.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../infrastructure/accounts/account_manager.dart';

class CalendarRepositoryImpl implements CalendarRepository {
  const CalendarRepositoryImpl({required this._accountManager});

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final events = await ds.getCalendarEvents(
        startDateTime: startDateTime,
        endDateTime: endDateTime,
      );
      return Right(events);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, CalendarEvent>> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.createCalendarEvent(params: params);
      return Right(event);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, CalendarEvent>> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.updateCalendarEvent(params: params);
      return Right(event);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.respondToMeetingInvite(
        emailId: emailId,
        response: response,
        icsData: icsData,
        meetingStart: meetingStart,
        userEmail: userEmail,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> cancelCalendarEvent({
    required String eventId,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    try {
      await ds.cancelCalendarEvent(eventId: eventId);
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> declineCalendarEvent({
    required String eventId,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.declineCalendarEvent(eventId: eventId, userEmail: userEmail);
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? message,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.proposeNewTime(
        eventId: eventId,
        newStart: newStart,
        newEnd: newEnd,
        timezone: timezone,
        userEmail: userEmail,
        message: message,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
