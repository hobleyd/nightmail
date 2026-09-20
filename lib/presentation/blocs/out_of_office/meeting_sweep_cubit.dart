import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/calendar_event.dart';
import '../../../domain/usecases/cancel_calendar_event.dart';
import '../../../domain/usecases/decline_calendar_event.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import 'meeting_sweep_state.dart';

/// Finds the meetings an account is on the hook for during an Out of Office
/// window, and declines/cancels the ones the user picks.
///
/// Two different provider calls sit behind one screen because they are not
/// the same act: [DeclineCalendarEvent] withdraws this account's own RSVP;
/// [CancelCalendarEvent] on a meeting the user organizes emails every
/// attendee a cancellation notice on the user's behalf. The list keeps them
/// visually and behaviourally separate — organized meetings are never
/// pre-selected — rather than offering one "clear my calendar" action that
/// would cancel other people's meetings on the strength of a single toggle.
///
/// [load] passes its `accountId` straight through to `CalendarRepository` on
/// every call, so this works for whichever account Out of Office is being
/// edited for — not just the one active elsewhere in the app. An id that
/// names no signed-in account (the mailbox was removed between opening
/// Settings and saving, say) comes back from the repository as a
/// [ServerFailure], which [load] reports the same as any other fetch error.
class MeetingSweepCubit extends Cubit<MeetingSweepState> {
  MeetingSweepCubit({
    required GetCalendarEvents getCalendarEvents,
    required DeclineCalendarEvent declineCalendarEvent,
    required CancelCalendarEvent cancelCalendarEvent,
  }) : _getEvents = getCalendarEvents,
       _decline = declineCalendarEvent,
       _cancel = cancelCalendarEvent,
       super(const MeetingSweepState());

  final GetCalendarEvents _getEvents;
  final DeclineCalendarEvent _decline;
  final CancelCalendarEvent _cancel;

  /// Set by [load] and reused by [confirm] — every decline/cancel in a sweep
  /// targets the same account the meetings were fetched for.
  String? _accountId;

  /// Fetches the meetings in [start, end] that need a decision: accepted
  /// invites and meetings the user organizes. Occurrences of a recurring
  /// series come back already expanded by [GetCalendarEvents] — each is
  /// declined/cancelled individually by its own occurrence id, never promoted
  /// to the series, so "away next week" cannot take out a standing meeting.
  Future<void> load({
    required String accountId,
    required DateTime start,
    required DateTime end,
  }) async {
    _accountId = accountId;
    emit(
      MeetingSweepState(
        status: MeetingSweepStatus.loading,
        windowStart: start,
        windowEnd: end,
      ),
    );

    final result = await _getEvents(
      GetCalendarEventsParams(
        startDateTime: start,
        endDateTime: end,
        accountId: accountId,
      ),
    );
    if (isClosed) return;

    result.fold(
      (failure) => emit(
        state.copyWith(
          status: MeetingSweepStatus.error,
          errorMessage: failure.message,
        ),
      ),
      (events) {
        final accepted = events
            .where(
              (e) =>
                  !e.isOrganizer &&
                  e.participation == MeetingParticipation.accepted,
            )
            .toList();
        final organized = events.where((e) => e.isOrganizer).toList();

        if (accepted.isEmpty && organized.isEmpty) {
          emit(state.copyWith(status: MeetingSweepStatus.empty));
          return;
        }

        emit(
          state.copyWith(
            status: MeetingSweepStatus.ready,
            accepted: accepted,
            organized: organized,
            // Accepted meetings start ticked — declining is the low-stakes
            // half of this. Organized meetings never do: cancelling one
            // emails every attendee, and that has to be opted into per
            // meeting, not inherited from a toggle meant for the user's own
            // RSVPs.
            selectedIds: {for (final e in accepted) e.id},
          ),
        );
      },
    );
  }

  void toggle(String eventId) {
    if (state.status != MeetingSweepStatus.ready) return;
    final selected = {...state.selectedIds};
    if (!selected.remove(eventId)) selected.add(eventId);
    emit(state.copyWith(selectedIds: selected));
  }

  void selectAll(bool selected) {
    if (state.status != MeetingSweepStatus.ready) return;
    emit(
      state.copyWith(
        selectedIds: selected
            ? {
                for (final e in [...state.accepted, ...state.organized]) e.id,
              }
            : const {},
      ),
    );
  }

  /// Declines every selected accepted meeting and cancels every selected
  /// organized one. Each call is independent: one failing must not stop the
  /// rest, and none of this is queued for retry — it emails people, and a
  /// blind replay would do that twice. [MeetingSweepState.results] carries
  /// what actually happened to each meeting so the confirmation can say so.
  Future<void> confirm() async {
    if (state.status != MeetingSweepStatus.ready) return;
    final accountId = _accountId;
    final toDecline = state.accepted.where(
      (e) => state.selectedIds.contains(e.id),
    );
    final toCancel = state.organized.where(
      (e) => state.selectedIds.contains(e.id),
    );
    if (toDecline.isEmpty && toCancel.isEmpty) {
      emit(state.copyWith(status: MeetingSweepStatus.done, results: const []));
      return;
    }

    emit(state.copyWith(status: MeetingSweepStatus.applying));

    final results = <MeetingSweepResult>[];
    for (final event in toDecline) {
      final result = await _decline(
        DeclineCalendarEventParams(eventId: event.id, accountId: accountId),
      );
      results.add(
        result.fold(
          (failure) => MeetingSweepResult(
            eventId: event.id,
            subject: event.subject,
            action: MeetingSweepAction.decline,
            succeeded: false,
            errorMessage: failure.message,
          ),
          (_) => MeetingSweepResult(
            eventId: event.id,
            subject: event.subject,
            action: MeetingSweepAction.decline,
            succeeded: true,
          ),
        ),
      );
    }
    for (final event in toCancel) {
      final result = await _cancel(
        CancelCalendarEventParams(eventId: event.id, accountId: accountId),
      );
      results.add(
        result.fold(
          (failure) => MeetingSweepResult(
            eventId: event.id,
            subject: event.subject,
            action: MeetingSweepAction.cancel,
            succeeded: false,
            errorMessage: failure.message,
          ),
          (_) => MeetingSweepResult(
            eventId: event.id,
            subject: event.subject,
            action: MeetingSweepAction.cancel,
            succeeded: true,
          ),
        ),
      );
    }

    if (isClosed) return;
    emit(state.copyWith(status: MeetingSweepStatus.done, results: results));
  }
}
