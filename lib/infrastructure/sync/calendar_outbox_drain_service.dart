import 'dart:convert';

import '../../core/error/exceptions.dart';
import '../../data/datasources/local/pending_calendar_operations_datasource.dart';
import '../../data/datasources/remote/calendar_remote_datasource.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/entities/meeting_notify_scope.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import '../network/connectivity_service.dart';

/// Replays queued calendar mutations (see
/// [PendingCalendarOperationsDatasource]) against the provider, so an
/// accept/decline/reschedule that was applied to the local calendar cache
/// eventually reaches the real calendar.
///
/// The calendar keeps its own outbox rather than sharing the mail one
/// ([OutboxDrainService]): that queue is drained strictly serially per account
/// because its ops contend for a single IMAP connection and can renumber each
/// other's message ids. Calendar ops have neither property, and putting them
/// behind a stuck mailbox mutation would delay an RSVP for no reason.
///
/// Ordering *within* one target is still preserved — accept-then-reschedule of
/// the same meeting only means anything in the order the user did it — and a
/// failure quarantines just that target for the pass, leaving other meetings'
/// mutations to go through.
class CalendarOutboxDrainService {
  CalendarOutboxDrainService({
    required PendingCalendarOperationsDatasource pendingOperations,
    required AccountManager accountManager,
    required ConnectivityService connectivityService,
  })  : _pendingOperations = pendingOperations,
        _accountManager = accountManager,
        _connectivityService = connectivityService;

  final PendingCalendarOperationsDatasource _pendingOperations;
  final AccountManager _accountManager;
  final ConnectivityService _connectivityService;

  /// Backstop so a mutation the provider will never accept (a meeting deleted
  /// by the organizer, a calendar we lost access to) stops being retried.
  static const int _maxOpRetries = 25;

  /// Chains concurrent drains for the same account, so overlapping triggers
  /// (one fired after each mutation, plus the periodic cache sync) don't
  /// replay the same op twice. Chaining rather than dropping means an op
  /// queued mid-drain is still picked up by the next pass.
  final Map<String, Future<void>> _inFlight = {};

  /// Drains every account's calendar outbox. Safe to call opportunistically —
  /// an account with an empty queue returns immediately.
  Future<void> drainAll() async {
    for (final account in _accountManager.accounts) {
      await drainForAccount(account.id);
    }
  }

  Future<void> drainForAccount(String accountId) {
    final prior = _inFlight[accountId] ?? Future.value();
    final next = prior
        .then((_) => _drainInner(accountId))
        // A failed drain must not wedge this account's chain — the next call
        // still has to run.
        .catchError((_) {});
    _inFlight[accountId] = next;
    return next;
  }

  Future<void> _drainInner(String accountId) async {
    // Drains are fired unawaited straight after every mutation, so without
    // this check a mutation made offline would push a real request into the
    // HTTP client's ~30s connect timeout every single time instead of simply
    // waiting for the next attempt.
    if (!await _connectivityService.isOnline) return;

    Account? account;
    for (final a in _accountManager.accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    if (account == null) return;

    final ds = _datasourceFor(account);
    if (ds == null) return;

    final ops = await _pendingOperations.getPendingCalendarOperations(accountId);
    final userEmail = account.emailAddress;

    // Targets whose op chain hit a failure this pass. Their remaining ops stay
    // queued for the next drain; other meetings are unaffected.
    final quarantined = <String>{};

    for (final op in ops) {
      if (quarantined.contains(op.targetId)) continue;
      try {
        await _replay(ds, op, userEmail);
        await _pendingOperations.removeCalendarOperation(op.id);
      } catch (e) {
        // A 404/410 means the event or invitation is already gone server-side,
        // so the mutation's intent is satisfied and no retry can ever succeed.
        // Drop it, along with anything that has burned through its retries.
        final targetGone = e is ServerException &&
            (e.statusCode == 404 || e.statusCode == 410);
        final exhausted = op.retryCount + 1 >= _maxOpRetries;
        if (targetGone || exhausted) {
          await _pendingOperations.removeCalendarOperation(op.id);
        } else {
          await _pendingOperations.recordCalendarOperationFailure(
            id: op.id,
            error: e.toString(),
          );
        }
        quarantined.add(op.targetId);
      }
    }
  }

  Future<void> _replay(
    CalendarRemoteDatasource ds,
    PendingCalendarOperationRecord op,
    String? userEmail,
  ) async {
    final payload = op.payload.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(op.payload) as Map<String, dynamic>;

    switch (op.opType) {
      case PendingCalendarOperationType.cancelEvent:
        await ds.cancelCalendarEvent(eventId: op.targetId);

      case PendingCalendarOperationType.cancelSeries:
        await ds.cancelCalendarEventSeries(
          eventId: op.targetId,
          seriesMasterId: payload['seriesMasterId'] as String?,
          occurrenceStart:
              DateTime.parse(payload['occurrenceStart'] as String),
        );

      case PendingCalendarOperationType.declineEvent:
        await ds.declineCalendarEvent(
          eventId: op.targetId,
          userEmail: userEmail,
        );

      case PendingCalendarOperationType.proposeNewTime:
        await ds.proposeNewTime(
          eventId: op.targetId,
          newStart: DateTime.parse(payload['newStart'] as String),
          newEnd: DateTime.parse(payload['newEnd'] as String),
          timezone: payload['timezone'] as String?,
          userEmail: userEmail,
          message: payload['message'] as String?,
        );

      case PendingCalendarOperationType.updateEvent:
        await ds.updateCalendarEvent(
          params: updateParamsFromJson(op.targetId, payload),
        );

      case PendingCalendarOperationType.respondToInvite:
        await ds.respondToMeetingInvite(
          emailId: op.targetId,
          response: MeetingInviteResponseType.values
              .byName(payload['response'] as String),
          icsData: payload['icsData'] as String?,
          meetingStart: _parseNullableDate(payload['meetingStart']),
          userEmail: userEmail,
          message: payload['message'] as String?,
        );

      case PendingCalendarOperationType.removeMeetingFromCalendar:
        await ds.removeMeetingFromCalendar(
          emailId: op.targetId,
          icsData: payload['icsData'] as String?,
          meetingStart: _parseNullableDate(payload['meetingStart']),
        );
    }
  }

  /// Calendar datasource for [account].
  ///
  /// The active account reuses [AccountManager]'s shared datasource rather than
  /// building its own: `buildCalendarDatasourceForAccount` stands up an
  /// independent auth pipeline against the same stored token, and running that
  /// alongside the active one races on refresh (the same trade-off
  /// `CalendarReminderService._reconcileAccount` documents).
  CalendarRemoteDatasource? _datasourceFor(Account account) {
    return account.id == _accountManager.activeAccount?.id
        ? _accountManager.calendarDatasource
        : _accountManager.buildCalendarDatasourceForAccount(account);
  }

  static DateTime? _parseNullableDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  // ---------------------------------------------------------------------------
  // updateEvent payload
  // ---------------------------------------------------------------------------

  /// Serialises the params of an `updateCalendarEvent` for the queue. Kept here
  /// beside [updateParamsFromJson] so the two halves cannot drift apart.
  static Map<String, dynamic> updateParamsToJson(
      UpdateCalendarEventParams p) =>
      {
        'subject': p.subject,
        'start': p.start.toIso8601String(),
        'end': p.end.toIso8601String(),
        'isAllDay': p.isAllDay,
        'timezone': p.timezone,
        'location': p.location,
        'description': p.description,
        'attendeeEmails': p.attendeeEmails,
        'roomEmails': p.roomEmails,
        'recurrence': _recurrenceToJson(p.recurrence),
        'isOnlineMeeting': p.isOnlineMeeting,
        'reminderMinutes': p.reminderMinutes,
        'notifyScope': p.notifyScope.name,
      };

  static UpdateCalendarEventParams updateParamsFromJson(
    String id,
    Map<String, dynamic> j,
  ) =>
      UpdateCalendarEventParams(
        id: id,
        subject: j['subject'] as String? ?? '',
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        isAllDay: j['isAllDay'] as bool? ?? false,
        timezone: j['timezone'] as String? ?? 'UTC',
        location: j['location'] as String?,
        description: j['description'] as String?,
        attendeeEmails:
            (j['attendeeEmails'] as List<dynamic>? ?? const []).cast<String>(),
        // Absent in ops queued before rooms were bookable. Replaying one of
        // those releases its rooms, which is the safe direction: the alternative
        // is guessing which of its attendees were rooms and re-booking them.
        roomEmails:
            (j['roomEmails'] as List<dynamic>? ?? const []).cast<String>(),
        recurrence: _recurrenceFromJson(j['recurrence'] as Map<String, dynamic>?),
        isOnlineMeeting: j['isOnlineMeeting'] as bool? ?? false,
        reminderMinutes: j['reminderMinutes'] as int?,
        notifyScope: MeetingNotifyScope.values.firstWhere(
          (s) => s.name == j['notifyScope'],
          orElse: () => MeetingNotifyScope.all,
        ),
      );

  static Map<String, dynamic>? _recurrenceToJson(CalendarRecurrence? r) {
    if (r == null) return null;
    return {
      'frequency': r.frequency.name,
      'interval': r.interval,
      'daysOfWeek': r.daysOfWeek,
      'endDate': r.endDate?.toIso8601String(),
      'count': r.count,
    };
  }

  static CalendarRecurrence? _recurrenceFromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final endDate = j['endDate'] as String?;
    return CalendarRecurrence(
      frequency: RecurrenceFrequency.values.firstWhere(
        (f) => f.name == j['frequency'],
        orElse: () => RecurrenceFrequency.daily,
      ),
      interval: j['interval'] as int? ?? 1,
      daysOfWeek: (j['daysOfWeek'] as List<dynamic>?)?.cast<int>(),
      endDate: endDate == null ? null : DateTime.tryParse(endDate),
      count: j['count'] as int?,
    );
  }
}
