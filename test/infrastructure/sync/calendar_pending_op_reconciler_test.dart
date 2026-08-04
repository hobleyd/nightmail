// The reconciler is what stops an optimistic calendar change from flickering
// back when a server snapshot taken *before* the queued mutation landed is
// written over it. These exercise the pure `apply` half, one op type at a time.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/pending_calendar_operations_datasource.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/sync/calendar_outbox_drain_service.dart';
import 'package:nightmail/infrastructure/sync/calendar_pending_op_reconciler.dart';

UpdateCalendarEventParams _params({
  required String id,
  required DateTime start,
  required String subject,
}) =>
    UpdateCalendarEventParams(
      id: id,
      subject: subject,
      start: start,
      end: start.add(const Duration(hours: 1)),
      isAllDay: false,
      timezone: 'UTC',
    );

void main() {
  DateTime at(int day, int hour) => DateTime.utc(2026, 6, day, hour);

  CalendarEvent event(
    String id, {
    DateTime? start,
    DateTime? end,
    String? iCalUid,
    String? seriesMasterId,
    MeetingParticipation participation = MeetingParticipation.needsAction,
  }) =>
      CalendarEvent(
        id: id,
        subject: 'Meeting $id',
        start: start ?? at(10, 9),
        end: end ?? at(10, 10),
        isAllDay: false,
        iCalUid: iCalUid,
        seriesMasterId: seriesMasterId,
        participation: participation,
      );

  var _nextId = 1;
  PendingCalendarOperationRecord op(
    PendingCalendarOperationType type,
    String targetId, [
    Map<String, dynamic> payload = const {},
  ]) =>
      PendingCalendarOperationRecord(
        id: _nextId++,
        accountId: 'acc1',
        targetId: targetId,
        opType: type,
        payload: jsonEncode(payload),
        createdAtMs: _nextId,
        retryCount: 0,
        lastError: null,
      );

  const ics = 'BEGIN:VCALENDAR\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:uid-1\r\n'
      'SUMMARY:Stand-up\r\n'
      'DTSTART:20260610T090000Z\r\n'
      'DTEND:20260610T100000Z\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR';

  group('event-targeted ops', () {
    test('a queued cancel keeps the meeting out of a stale snapshot', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1'), event('e2')],
        [op(PendingCalendarOperationType.cancelEvent, 'e1')],
      );

      expect(result.map((e) => e.id), ['e2']);
    });

    test('a queued series cancel removes every occurrence', () {
      final result = CalendarPendingOpReconciler.apply(
        [
          event('occ-1', seriesMasterId: 'master-1'),
          event('occ-2', start: at(17, 9), seriesMasterId: 'master-1'),
          event('other'),
        ],
        [
          op(PendingCalendarOperationType.cancelSeries, 'occ-1', {
            'seriesMasterId': 'master-1',
            'occurrenceStart': at(10, 9).toIso8601String(),
          }),
        ],
      );

      expect(result.map((e) => e.id), ['other']);
    });

    test('a series cancel with no master id reads it off the occurrence', () {
      final result = CalendarPendingOpReconciler.apply(
        [
          event('occ-1', seriesMasterId: 'master-1'),
          event('occ-2', start: at(17, 9), seriesMasterId: 'master-1'),
        ],
        [
          op(PendingCalendarOperationType.cancelSeries, 'occ-1', {
            'occurrenceStart': at(10, 9).toIso8601String(),
          }),
        ],
      );

      expect(result, isEmpty);
    });

    test('a queued decline keeps the meeting marked declined', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', participation: MeetingParticipation.needsAction)],
        [op(PendingCalendarOperationType.declineEvent, 'e1')],
      );

      expect(result.single.participation, MeetingParticipation.declined);
    });

    test('a queued propose-new-time also reads as declined', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1')],
        [
          op(PendingCalendarOperationType.proposeNewTime, 'e1', {
            'newStart': at(11, 9).toIso8601String(),
            'newEnd': at(11, 10).toIso8601String(),
          }),
        ],
      );

      // Only the organizer accepting moves the meeting; our copy is declined.
      expect(result.single.participation, MeetingParticipation.declined);
      expect(result.single.start, at(10, 9));
    });

    test('a queued update keeps the meeting at its new time', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', iCalUid: 'uid-1', seriesMasterId: 'master-1')],
        [
          op(
            PendingCalendarOperationType.updateEvent,
            'e1',
            CalendarOutboxDrainService.updateParamsToJson(
              _params(id: 'e1', start: at(11, 14), subject: 'Moved'),
            ),
          ),
        ],
      );

      final e = result.single;
      expect(e.start, at(11, 14));
      expect(e.subject, 'Moved');
      // Fields the save params never carried survive the re-application.
      expect(e.iCalUid, 'uid-1');
      expect(e.seriesMasterId, 'master-1');
    });

    test('an op for a meeting not in the snapshot changes nothing', () {
      final events = [event('e1')];
      final result = CalendarPendingOpReconciler.apply(
        events,
        [op(PendingCalendarOperationType.declineEvent, 'gone')],
      );

      expect(result.single.participation, MeetingParticipation.needsAction);
    });
  });

  group('invitation-targeted ops', () {
    test('an accept is re-applied to the copy matched by ICS UID', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', iCalUid: 'uid-1'), event('e2', iCalUid: 'uid-other')],
        [
          op(PendingCalendarOperationType.respondToInvite, 'mail-1',
              {'response': 'accept', 'icsData': ics}),
        ],
      );

      expect(result.first.participation, MeetingParticipation.accepted);
      expect(result.first.status, CalendarEventStatus.busy);
      expect(result.last.participation, MeetingParticipation.needsAction);
    });

    test('with no ICS it falls back to an unambiguous start time', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', start: at(10, 9))],
        [
          op(PendingCalendarOperationType.respondToInvite, 'mail-1', {
            'response': 'tentative',
            'meetingStart': at(10, 9).toIso8601String(),
          }),
        ],
      );

      expect(result.single.participation, MeetingParticipation.tentative);
      expect(result.single.status, CalendarEventStatus.tentative);
    });

    test('two meetings at the same time are left alone rather than guessed at',
        () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', start: at(10, 9)), event('e2', start: at(10, 9))],
        [
          op(PendingCalendarOperationType.respondToInvite, 'mail-1', {
            'response': 'accept',
            'meetingStart': at(10, 9).toIso8601String(),
          }),
        ],
      );

      expect(
        result.map((e) => e.participation),
        everyElement(MeetingParticipation.needsAction),
      );
    });

    test('a queued remove-from-calendar keeps the meeting out', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1', iCalUid: 'uid-1'), event('e2')],
        [
          op(PendingCalendarOperationType.removeMeetingFromCalendar, 'mail-1',
              {'icsData': ics}),
        ],
      );

      expect(result.map((e) => e.id), ['e2']);
    });
  });

  group('multiple ops', () {
    test('are applied oldest-first, matching the order they will be sent', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1')],
        [
          op(PendingCalendarOperationType.respondToInvite, 'mail-1', {
            'response': 'accept',
            'meetingStart': at(10, 9).toIso8601String(),
          }),
          op(
            PendingCalendarOperationType.updateEvent,
            'e1',
            CalendarOutboxDrainService.updateParamsToJson(
              _params(id: 'e1', start: at(11, 14), subject: 'Accepted, moved'),
            ),
          ),
        ],
      );

      final e = result.single;
      // The accept's participation survives the later update, because the
      // update is applied on top of the already-accepted event.
      expect(e.participation, MeetingParticipation.accepted);
      expect(e.start, at(11, 14));
      expect(e.subject, 'Accepted, moved');
    });

    test('a cancel after a decline still removes the meeting', () {
      final result = CalendarPendingOpReconciler.apply(
        [event('e1')],
        [
          op(PendingCalendarOperationType.declineEvent, 'e1'),
          op(PendingCalendarOperationType.cancelEvent, 'e1'),
        ],
      );

      expect(result, isEmpty);
    });
  });
}
