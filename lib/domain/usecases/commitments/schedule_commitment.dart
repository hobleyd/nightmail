import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/timezone_utils.dart';
import '../../entities/calendar_event.dart';
import '../../entities/commitment.dart';
import '../../repositories/commitment_repository.dart';
import '../create_calendar_event.dart';
import '../update_calendar_event.dart';

/// Blocks time on the calendar for a commitment and records the block on the
/// ledger.
///
/// A commitment that already has a block has that event *moved*; if the move
/// fails (the event was deleted by hand) a fresh one is created instead. The
/// event's subject is written to read in a week view, the commitment's
/// excerpt goes in the description, and the block carries the app's default
/// reminder. Shared by the scheduling dialog, the rebalance plan and the
/// commitments agent, so all three book exactly the same way.
class ScheduleCommitment {
  const ScheduleCommitment({
    required this.createCalendarEvent,
    required this.updateCalendarEvent,
    required this.commitmentRepository,
  });

  final CreateCalendarEvent createCalendarEvent;
  final UpdateCalendarEvent updateCalendarEvent;
  final CommitmentRepository commitmentRepository;

  /// Reminder on a scheduled block, matching the app's default for new
  /// meetings.
  static const int reminderMinutes = 15;

  /// Returns the commitment with its new block recorded.
  Future<Either<Failure, Commitment>> call(
    Commitment commitment, {
    required DateTime start,
    required DateTime end,
  }) async {
    if (!end.isAfter(start)) {
      return const Left(
        UnsupportedFailure(message: 'A time block must end after it starts.'),
      );
    }

    final subject = subjectFor(commitment);
    final description = descriptionFor(commitment);
    final timezone = localIanaTimezone();

    Either<Failure, CalendarEvent> result;
    final existingId = commitment.scheduledEventId;
    if (existingId != null) {
      result = await updateCalendarEvent(UpdateCalendarEventParams(
        id: existingId,
        subject: subject,
        start: start,
        end: end,
        isAllDay: false,
        timezone: timezone,
        description: description,
        reminderMinutes: reminderMinutes,
      ));
      if (result.isLeft()) {
        // The old block may have been deleted from the calendar; fall back
        // to a fresh one rather than failing the reschedule.
        result = await _create(subject, start, end, timezone, description);
      }
    } else {
      result = await _create(subject, start, end, timezone, description);
    }

    final event = result.fold((_) => null, (e) => e);
    if (event == null) return Left(result.getLeft().toNullable()!);

    final saved = await commitmentRepository.setSchedule(
      accountId: commitment.accountId,
      id: commitment.id,
      eventId: event.id,
      start: start,
      end: end,
    );
    if (saved.isLeft()) return Left(saved.getLeft().toNullable()!);

    return Right(commitment.copyWith(
      scheduledEventId: event.id,
      scheduledStart: start,
      scheduledEnd: end,
    ));
  }

  Future<Either<Failure, CalendarEvent>> _create(
    String subject,
    DateTime start,
    DateTime end,
    String timezone,
    String description,
  ) {
    return createCalendarEvent(CreateCalendarEventParams(
      subject: subject,
      start: start,
      end: end,
      isAllDay: false,
      timezone: timezone,
      description: description,
      reminderMinutes: reminderMinutes,
    ));
  }

  /// The calendar subject for a commitment's block — what it is for and who
  /// it involves, readable in a week view at a glance.
  static String subjectFor(Commitment c) {
    final what = c.subject.trim().isEmpty ? 'Commitment' : c.subject.trim();
    final who = c.counterpart.displayName;
    return switch (c.kind) {
      CommitmentKind.iOwe => '$what — for $who',
      CommitmentKind.theyOweMe => 'Follow up with $who: $what',
      CommitmentKind.needsAction => 'Reply to $who: $what',
    };
  }

  static String descriptionFor(Commitment c) {
    final kind = switch (c.kind) {
      CommitmentKind.iOwe => 'Something you promised',
      CommitmentKind.theyOweMe => 'Something you are waiting on',
      CommitmentKind.needsAction => 'Mail that needs your decision',
    };
    final snippet = c.snippet.trim();
    return [
      'Time blocked from NightMail Commitments.',
      '$kind · ${c.counterpart.displayName} <${c.counterpart.address}>',
      if (snippet.isNotEmpty) '',
      if (snippet.isNotEmpty) snippet,
    ].join('\n');
  }
}
