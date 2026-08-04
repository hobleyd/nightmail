import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/utils/calendar_event_patch.dart';
import '../../core/utils/ics_parser.dart';
import '../../data/datasources/local/pending_calendar_operations_datasource.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/meeting_invite.dart';
import 'calendar_outbox_drain_service.dart';

/// Re-applies still-queued calendar mutations on top of a fresh provider fetch.
///
/// Without this, an optimistic change visibly flickers back. Declining a meeting
/// writes the cache and queues the decline, then the calendar refreshes its
/// week; if that fetch resolves before the queued decline reaches the provider —
/// which is the normal case, since the two go out together — the response still
/// shows the meeting unanswered, and writing it back would undo what the user
/// just did on screen. So every fetch is passed through here before it is cached
/// or displayed.
///
/// This is the calendar's counterpart of `EmailRepositoryImpl`'s
/// `_reconcileAgainstPendingOps`.
class CalendarPendingOpReconciler {
  const CalendarPendingOpReconciler(this._pendingOperations);

  final PendingCalendarOperationsDatasource _pendingOperations;

  /// [events] with every queued mutation for [accountId] applied.
  Future<List<CalendarEvent>> reconcile({
    required String accountId,
    required List<CalendarEvent> events,
  }) async {
    final ops =
        await _pendingOperations.getPendingCalendarOperations(accountId);
    if (ops.isEmpty) return events;
    return apply(events, ops);
  }

  /// The pure half, so the op-by-op behaviour can be tested without a database.
  ///
  /// Ops are applied oldest-first, matching the order they will reach the
  /// provider in, so an accept followed by a reschedule of the same meeting
  /// lands the same way here as it will there.
  @visibleForTesting
  static List<CalendarEvent> apply(
    List<CalendarEvent> events,
    List<PendingCalendarOperationRecord> ops,
  ) {
    var result = List<CalendarEvent>.of(events);

    for (final op in ops) {
      final payload = _decode(op.payload);
      switch (op.opType) {
        case PendingCalendarOperationType.cancelEvent:
          result.removeWhere((e) => e.id == op.targetId);

        case PendingCalendarOperationType.cancelSeries:
          final masterId = payload['seriesMasterId'] as String? ??
              result
                  .where((e) => e.id == op.targetId)
                  .map((e) => e.seriesMasterId)
                  .firstOrNull;
          result.removeWhere((e) =>
              e.id == op.targetId ||
              (masterId != null &&
                  (e.id == masterId || e.seriesMasterId == masterId)));

        case PendingCalendarOperationType.declineEvent:
        case PendingCalendarOperationType.proposeNewTime:
          // Proposing a new time declines your copy everywhere — only the
          // organizer accepting actually moves the meeting.
          result = _replaceById(
            result,
            op.targetId,
            (e) => applyRsvp(e, MeetingInviteResponseType.decline),
          );

        case PendingCalendarOperationType.updateEvent:
          result = _replaceById(
            result,
            op.targetId,
            (e) => applyUpdate(
              e,
              CalendarOutboxDrainService.updateParamsFromJson(
                  op.targetId, payload),
            ),
          );

        case PendingCalendarOperationType.respondToInvite:
          final response = _responseOf(payload['response']);
          if (response == null) break;
          result = _replaceMatch(
            result,
            payload,
            (e) => applyRsvp(e, response),
          );

        case PendingCalendarOperationType.removeMeetingFromCalendar:
          final match = _findMatch(result, payload);
          if (match != null) result.removeWhere((e) => e.id == match.id);
      }
    }

    return result;
  }

  static List<CalendarEvent> _replaceById(
    List<CalendarEvent> events,
    String eventId,
    CalendarEvent Function(CalendarEvent) patch,
  ) =>
      [for (final e in events) if (e.id == eventId) patch(e) else e];

  static List<CalendarEvent> _replaceMatch(
    List<CalendarEvent> events,
    Map<String, dynamic> payload,
    CalendarEvent Function(CalendarEvent) patch,
  ) {
    final match = _findMatch(events, payload);
    if (match == null) return events;
    return _replaceById(events, match.id, patch);
  }

  /// Locates the meeting an invitation-side op refers to, by the same two rules
  /// `CalendarRepositoryImpl._findCachedMeeting` uses — the ICS `UID` first,
  /// then an unambiguous start-time match for providers (Microsoft) whose
  /// invitations carry no calendar part.
  static CalendarEvent? _findMatch(
    List<CalendarEvent> events,
    Map<String, dynamic> payload,
  ) {
    final ics = payload['icsData'] as String?;
    final uid = ics == null ? null : _uidOf(ics);
    if (uid != null && uid.isNotEmpty) {
      for (final e in events) {
        if (e.iCalUid == uid) return e;
      }
    }

    final startRaw = payload['meetingStart'] as String?;
    final start = startRaw == null ? null : DateTime.tryParse(startRaw);
    if (start == null) return null;
    final utc = start.toUtc();
    final atStart = events
        .where((e) => e.start.difference(utc).abs() <= _startSlack)
        .toList();
    return atStart.length == 1 ? atStart.first : null;
  }

  static const _startSlack = Duration(minutes: 1);

  static Map<String, dynamic> _decode(String payload) {
    if (payload.isEmpty) return const {};
    try {
      return jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static String? _uidOf(String icsData) {
    try {
      return IcsParser.parse(icsData).uid;
    } catch (_) {
      return null;
    }
  }

  static MeetingInviteResponseType? _responseOf(Object? name) {
    for (final r in MeetingInviteResponseType.values) {
      if (r.name == name) return r;
    }
    return null;
  }
}
