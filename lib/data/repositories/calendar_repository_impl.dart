import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fpdart/fpdart.dart';
import 'package:intl/intl.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../core/utils/calendar_event_patch.dart';
import '../../core/utils/ics_counter_builder.dart';
import '../../core/utils/ics_parser.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/local_attachment.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/repositories/calendar_repository.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/sync/calendar_outbox_drain_service.dart';
import '../../infrastructure/sync/calendar_pending_op_reconciler.dart';
import '../datasources/local/calendar_local_datasource.dart';
import '../datasources/local/pending_calendar_operations_datasource.dart';
import '../datasources/remote/calendar_remote_datasource.dart';

/// Calendar reads are served from a local cache first and mutations are applied
/// to that cache before the provider is told, so an RSVP or a drag lands on
/// screen at once instead of after a round-trip.
///
/// **Mutation order is cache, then queue, then send** — the reverse of the mail
/// outbox ([EmailRepositoryImpl], which enqueues before touching the cache).
/// The difference is that a calendar cache row is entirely re-derived from the
/// provider by every `CalendarCacheSyncService` pass, so a crash between the
/// local write and the enqueue heals itself on the next sync. Mail read-state
/// has no such authority to fall back on, which is why it must be durable
/// before it is visible.
///
/// Which mutations are queued and which still wait for the server is recorded
/// on [PendingCalendarOperationType]; the short version is that anything which
/// emails other people is not safe to replay blindly.
class CalendarRepositoryImpl implements CalendarRepository {
  const CalendarRepositoryImpl({
    required AccountManager accountManager,
    required CalendarLocalDatasource localDatasource,
    required PendingCalendarOperationsDatasource pendingOperations,
    required CalendarOutboxDrainService outboxDrainService,
    required CalendarPendingOpReconciler pendingOpReconciler,
  })  : _accountManager = accountManager,
        _localDatasource = localDatasource,
        _pendingOperations = pendingOperations,
        _outboxDrainService = outboxDrainService,
        _pendingOpReconciler = pendingOpReconciler;

  final AccountManager _accountManager;
  final CalendarLocalDatasource _localDatasource;
  final PendingCalendarOperationsDatasource _pendingOperations;
  final CalendarOutboxDrainService _outboxDrainService;
  final CalendarPendingOpReconciler _pendingOpReconciler;

  /// Slack allowed when matching a cached meeting by its start time. Providers
  /// round these to the second, and an invitation's stated start can differ
  /// from the calendar copy's by a hair.
  static const _startSlack = Duration(minutes: 1);

  String? get _accountId => _accountManager.activeAccount?.id;

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

    // Bind the cache write to the account this fetch was issued for, before any
    // await: an account switch landing mid-fetch would otherwise file one
    // calendar's meetings under the other account's id.
    final accountId = _accountId;

    try {
      final fetched = await ds.getCalendarEvents(
        startDateTime: startDateTime,
        endDateTime: endDateTime,
      );
      if (accountId == null) return Right(fetched);

      // Re-apply anything still queued before this snapshot is cached *or*
      // returned. A mutation and this fetch go out together, so the response
      // routinely predates the queued op arriving at the provider — writing it
      // back un-reconciled is exactly what makes a just-declined meeting pop
      // back to unanswered on screen.
      final events = await _pendingOpReconciler.reconcile(
        accountId: accountId,
        events: fetched,
      );

      // Unawaited: the caller wants the events, not the disk write. A failure
      // is logged rather than surfaced — a cache that could not be written
      // costs a refetch next time, it does not make this result wrong.
      unawaited(_localDatasource
          .cacheEvents(
            accountId: accountId,
            windowStart: startDateTime,
            windowEnd: endDateTime,
            events: events,
          )
          .catchError((Object e) =>
              debugPrint('CalendarRepository: cache write failed: $e')));
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
  Future<Either<Failure, List<CalendarEvent>>> getCachedCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    final accountId = _accountId;
    if (accountId == null) return const Right([]);
    try {
      final events = await _localDatasource.getCachedEvents(
        accountId: accountId,
        start: startDateTime,
        end: endDateTime,
      );
      return Right(events);
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, CalendarEvent>> getCalendarEvent({
    required String id,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.getCalendarEvent(id: id);
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

    final accountId = _accountId;

    try {
      final event = await ds.createCalendarEvent(params: params);
      // Network-first by necessity — a cache row is keyed by the id the
      // provider assigns — but the new meeting is folded in straight away so it
      // does not vanish from the week until the next sync.
      if (accountId != null) {
        await _localDatasource.upsertEvent(accountId: accountId, event: event);
      }
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

    final accountId = _accountId;
    final cached = accountId == null
        ? null
        : await _localDatasource.getCachedEventById(
            accountId: accountId, eventId: params.id);

    // Nothing cached to rewrite (a meeting outside the cached window, or a
    // first run before any sync) — there is no optimistic result to hand back,
    // so wait for the provider as before rather than invent one.
    if (accountId == null || cached == null) {
      try {
        final event = await ds.updateCalendarEvent(params: params);
        if (accountId != null) {
          await _localDatasource.upsertEvent(
              accountId: accountId, event: event);
        }
        return Right(event);
      } on AuthException catch (e) {
        return Left(AuthFailure(message: e.message));
      } on NetworkException catch (e) {
        return Left(NetworkFailure(message: e.message));
      } on ServerException catch (e) {
        return Left(
            ServerFailure(message: e.message, statusCode: e.statusCode));
      } catch (e) {
        return Left(ServerFailure(message: e.toString()));
      }
    }

    final optimistic = applyUpdate(cached, params);
    return _cacheFirst(
      accountId: accountId,
      targetId: params.id,
      opType: PendingCalendarOperationType.updateEvent,
      payload: CalendarOutboxDrainService.updateParamsToJson(params),
      apply: () =>
          _localDatasource.upsertEvent(accountId: accountId, event: optimistic),
      value: optimistic,
    );
  }

  /// Finds the cached calendar copy of the meeting an invitation email is about.
  ///
  /// Two locators, in order of trustworthiness:
  ///
  /// 1. The iCalendar `UID` from [icsData], matched against
  ///    [CalendarEvent.iCalUid]. Exact, and shared by every attendee's copy —
  ///    this is what the field exists for.
  /// 2. [meetingStart], when there is no ICS to read a UID out of. Microsoft
  ///    invitations arrive as Graph `eventMessage`s with no calendar part at
  ///    all, so the stated start is the only handle. Accepted **only when
  ///    exactly one** cached meeting starts there: two meetings at 10:00 are
  ///    common enough that guessing between them would move the wrong one.
  ///
  /// Null means "don't apply anything optimistically", which sends the caller
  /// down the network-first path rather than risking the wrong meeting.
  Future<CalendarEvent?> _findCachedMeeting({
    required String accountId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final uid = icsData == null ? null : _uidOf(icsData);
    if (uid != null && uid.isNotEmpty) {
      final byUid = await _localDatasource.getCachedEventByICalUid(
        accountId: accountId,
        iCalUid: uid,
      );
      if (byUid != null) return byUid;
    }

    if (meetingStart == null) return null;
    final start = meetingStart.toUtc();
    final candidates = await _localDatasource.getCachedEvents(
      accountId: accountId,
      start: start.subtract(_startSlack),
      end: start.add(_startSlack),
    );
    final atStart = candidates
        .where((e) => e.start.difference(start).abs() <= _startSlack)
        .toList();
    return atStart.length == 1 ? atStart.first : null;
  }

  String? _uidOf(String icsData) {
    try {
      return IcsParser.parse(icsData).uid;
    } catch (_) {
      return null;
    }
  }

  /// Marks the cached copy of an invitation's meeting declined, if it can be
  /// found. Used by the network-first invitation paths; silently does nothing
  /// when there is no cached copy to mark.
  Future<void> _markCachedMeetingDeclined({
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final accountId = _accountId;
    if (accountId == null) return;
    final cached = await _findCachedMeeting(
      accountId: accountId,
      icsData: icsData,
      meetingStart: meetingStart,
    );
    if (cached == null) return;
    await _localDatasource.upsertEvent(
      accountId: accountId,
      event: applyRsvp(cached, MeetingInviteResponseType.decline),
    );
  }

  /// Applies a mutation to the local cache, queues it for replay against the
  /// provider, and returns [value] without waiting for that replay.
  ///
  /// Cache write first, enqueue second — see the class doc for why this is the
  /// opposite of the mail outbox's ordering. The drain is kicked unawaited so an
  /// online mutation still reaches the server within moments; offline, it fails
  /// fast on the connectivity check and waits for the next attempt.
  ///
  /// A [CacheFailure] here means the local write itself failed, which is the one
  /// case where nothing has been recorded anywhere and the caller must be told.
  Future<Either<Failure, T>> _cacheFirst<T>({
    required String accountId,
    required String targetId,
    required PendingCalendarOperationType opType,
    required Map<String, dynamic> payload,
    required Future<void> Function() apply,
    required T value,
  }) async {
    try {
      await apply();
      await _pendingOperations.enqueueCalendarOperation(
        accountId: accountId,
        targetId: targetId,
        opType: opType,
        payload: jsonEncode(payload),
      );
      unawaited(_outboxDrainService.drainForAccount(accountId));
      return Right(value);
    } catch (e) {
      return Left(CacheFailure(message: e.toString()));
    }
  }

  /// [_cacheFirst] for the mutations whose repository method returns nothing.
  Future<Either<Failure, void>> _cacheFirstVoid({
    required String accountId,
    required String targetId,
    required PendingCalendarOperationType opType,
    required Map<String, dynamic> payload,
    required Future<void> Function() apply,
  }) =>
      _cacheFirst<void>(
        accountId: accountId,
        targetId: targetId,
        opType: opType,
        payload: payload,
        apply: apply,
        value: null,
      );

  @override
  Future<Either<Failure, void>> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
    String? message,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    final accountId = _accountId;
    final cached = accountId == null
        ? null
        : await _findCachedMeeting(
            accountId: accountId,
            icsData: icsData,
            meetingStart: meetingStart,
          );

    if (accountId != null && cached != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: emailId,
        opType: PendingCalendarOperationType.respondToInvite,
        payload: {
          'response': response.name,
          'icsData': icsData,
          'meetingStart': meetingStart?.toIso8601String(),
          'message': message,
        },
        apply: () => _localDatasource.upsertEvent(
          accountId: accountId,
          event: applyRsvp(cached, response),
        ),
      );
    }

    // No cached copy of the meeting to move — most often an invitation the
    // provider has not put on the calendar yet. There is nothing to show
    // optimistically, so wait for the provider and report what it says.
    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.respondToMeetingInvite(
        emailId: emailId,
        response: response,
        icsData: icsData,
        meetingStart: meetingStart,
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

  @override
  Future<Either<Failure, void>> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
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
      await ds.proposeNewTimeFromEmail(
        emailId: emailId,
        newStart: newStart,
        newEnd: newEnd,
        icsData: icsData,
        meetingStart: meetingStart,
        userEmail: userEmail,
        message: message,
      );
      if (!ds.supportsNativeProposeNewTime) {
        await _emailCounterProposal(
          emailId: emailId,
          icsData: icsData,
          newStart: newStart,
          newEnd: newEnd,
          userEmail: userEmail,
          message: message,
        );
      }
      // Proposing a time *is* a decline everywhere — Graph declines with a
      // proposal attached, the rest decline and email a COUNTER — so the cached
      // copy follows. Patched after the fact, not before: this path sends mail
      // to the organizer and so is not queued (see
      // [PendingCalendarOperationType]).
      await _markCachedMeetingDeclined(
        icsData: icsData,
        meetingStart: meetingStart,
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

  /// Emails the organizer the proposed time, for account types whose provider
  /// can only decline (see [CalendarRemoteDatasource.supportsNativeProposeNewTime]).
  ///
  /// The reply carries a `METHOD:COUNTER` iCalendar part — what Outlook itself
  /// sends over SMTP, so Exchange can offer the organizer an "Accept Proposal"
  /// action — and states the proposed time in the message body as well, for
  /// clients that ignore COUNTER. Replying (rather than composing) keeps the
  /// proposal in the invitation's thread.
  ///
  /// Throws when the reply cannot be sent: by this point the invite has already
  /// been declined, and a silent failure would leave the organizer with a bare
  /// decline and no idea a time was proposed.
  Future<void> _emailCounterProposal({
    required String emailId,
    required String? icsData,
    required DateTime newStart,
    required DateTime newEnd,
    required String? userEmail,
    required String? message,
  }) async {
    final event = icsData != null ? IcsParser.parse(icsData) : null;
    final note = message?.trim();

    final body = StringBuffer()
      ..writeln(event != null
          ? 'I\'ve proposed a new time for "${event.summary}".'
          : "I've proposed a new time for this meeting.")
      ..writeln()
      ..writeln('Proposed: ${_formatRange(newStart, newEnd)}');
    if (event != null) {
      body.writeln('Originally: ${_formatRange(event.start, event.end)}');
    }
    if (note != null && note.isNotEmpty) {
      body
        ..writeln()
        ..writeln(note);
    }

    // No ICS (or no address to reply as) means no counter can be built — send
    // the plain-text proposal on its own rather than nothing at all.
    final counter = (icsData != null && userEmail != null)
        ? buildCounterIcs(
            originalIcs: icsData,
            attendeeEmail: userEmail,
            attendeeName: _accountManager.activeAccount?.displayName,
            newStart: newStart,
            newEnd: newEnd,
            comment: note,
          )
        : null;

    try {
      await _accountManager.emailDatasource.replyToEmail(
        messageId: emailId,
        comment: body.toString(),
        // Reply to the ICS organizer when it is known: the address an invite
        // was *sent* from can be a delegate or a room system.
        toAddresses: event?.organizer != null ? [event!.organizer!] : const [],
        newAttachments: counter == null
            ? const []
            : [
                LocalAttachment(
                  name: 'counter.ics',
                  // The `method` parameter is what makes Exchange read the part
                  // as a meeting counter-proposal rather than a file.
                  mimeType: 'text/calendar; method=COUNTER',
                  bytes: Uint8List.fromList(utf8.encode(counter)),
                ),
              ],
      );
      // Each exception is re-thrown as its own type so the caller still maps it
      // to the right Failure — an expired token has to stay an AuthFailure for
      // the re-auth prompt to appear.
    } on AuthException catch (e) {
      throw AuthException(message: _counterFailed(e.message));
    } on NetworkException catch (e) {
      throw NetworkException(message: _counterFailed(e.message));
    } on ServerException catch (e) {
      throw ServerException(
          message: _counterFailed(e.message), statusCode: e.statusCode);
    } catch (e) {
      throw ServerException(message: _counterFailed(e.toString()));
    }
  }

  String _counterFailed(String reason) =>
      'The invitation was declined, but the new time could not be sent to the '
      'organizer: $reason';

  String _formatRange(DateTime start, DateTime end) {
    final localStart = start.toLocal();
    final localEnd = end.toLocal();
    final date = DateFormat('EEE d MMM yyyy').format(localStart);
    final from = DateFormat('h:mm a').format(localStart);
    final to = DateFormat('h:mm a').format(localEnd);
    final sameDay = localStart.year == localEnd.year &&
        localStart.month == localEnd.month &&
        localStart.day == localEnd.day;
    final zone = localStart.timeZoneName;
    if (sameDay) return '$date, $from – $to ($zone)';
    final endDate = DateFormat('EEE d MMM yyyy').format(localEnd);
    return '$date $from – $endDate $to ($zone)';
  }

  @override
  Future<Either<Failure, void>> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final accountId = _accountId;
    final cached = accountId == null
        ? null
        : await _findCachedMeeting(
            accountId: accountId,
            icsData: icsData,
            meetingStart: meetingStart,
          );

    if (accountId != null && cached != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: emailId,
        opType: PendingCalendarOperationType.removeMeetingFromCalendar,
        payload: {
          'icsData': icsData,
          'meetingStart': meetingStart?.toIso8601String(),
        },
        apply: () => _localDatasource.deleteEvent(
          accountId: accountId,
          eventId: cached.id,
        ),
      );
    }

    try {
      await ds.removeMeetingFromCalendar(
        emailId: emailId,
        icsData: icsData,
        meetingStart: meetingStart,
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
  Future<Either<Failure, void>> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final accountId = _accountId;

    try {
      await ds.cancelMeetingFromEmail(
        emailId: emailId,
        meetingStart: meetingStart,
      );
      // Network-first: with no ICS on this path there is no UID to identify the
      // meeting by ahead of time, so the cached copy is dropped afterwards
      // instead — still soon enough that the week repaints without it.
      if (accountId != null) {
        final cached = await _findCachedMeeting(
          accountId: accountId,
          meetingStart: meetingStart,
        );
        if (cached != null) {
          await _localDatasource.deleteEvent(
            accountId: accountId,
            eventId: cached.id,
          );
        }
      }
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
  Future<Either<Failure, void>> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final accountId = _accountId;

    try {
      await ds.acceptProposedTimeFromEmail(
        emailId: emailId,
        newStart: newStart,
        newEnd: newEnd,
        icsData: icsData,
        meetingStart: meetingStart,
      );
      // Moved to the proposed slot in the cache too, so the week redraws it at
      // its new time. After the fact rather than before, because this re-issues
      // the invitation to every attendee and so is not queued (see
      // [PendingCalendarOperationType]).
      if (accountId != null) {
        final cached = await _findCachedMeeting(
          accountId: accountId,
          icsData: icsData,
          meetingStart: meetingStart,
        );
        if (cached != null) {
          await _localDatasource.upsertEvent(
            accountId: accountId,
            event: cached.copyWith(start: newStart, end: newEnd),
          );
        }
      }
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

    final accountId = _accountId;
    if (accountId != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: eventId,
        opType: PendingCalendarOperationType.cancelEvent,
        payload: const {},
        apply: () => _localDatasource.deleteEvent(
            accountId: accountId, eventId: eventId),
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
  Future<Either<Failure, void>> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final accountId = _accountId;
    if (accountId != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: eventId,
        opType: PendingCalendarOperationType.cancelSeries,
        payload: {
          'seriesMasterId': seriesMasterId,
          'occurrenceStart': occurrenceStart.toIso8601String(),
        },
        // Every cached occurrence goes, not just the clicked one — cancelling a
        // series that left its other weeks on screen would read as a failure.
        apply: () => _localDatasource.deleteSeries(
          accountId: accountId,
          eventId: eventId,
          seriesMasterId: seriesMasterId,
        ),
      );
    }

    try {
      await ds.cancelCalendarEventSeries(
        eventId: eventId,
        seriesMasterId: seriesMasterId,
        occurrenceStart: occurrenceStart,
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
    final accountId = _accountId;
    final cached = accountId == null
        ? null
        : await _localDatasource.getCachedEventById(
            accountId: accountId, eventId: eventId);

    if (accountId != null && cached != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: eventId,
        opType: PendingCalendarOperationType.declineEvent,
        payload: const {},
        apply: () => _localDatasource.upsertEvent(
          accountId: accountId,
          event: applyRsvp(cached, MeetingInviteResponseType.decline),
        ),
      );
    }

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
    final accountId = _accountId;
    final cached = accountId == null
        ? null
        : await _localDatasource.getCachedEventById(
            accountId: accountId, eventId: eventId);

    if (accountId != null && cached != null) {
      return _cacheFirstVoid(
        accountId: accountId,
        targetId: eventId,
        opType: PendingCalendarOperationType.proposeNewTime,
        payload: {
          'newStart': newStart.toIso8601String(),
          'newEnd': newEnd.toIso8601String(),
          'timezone': timezone,
          'message': message,
        },
        // Proposing does not move the meeting — only the organizer can do that,
        // by accepting. What it does do is decline our copy, which is what the
        // cache reflects until they answer.
        apply: () => _localDatasource.upsertEvent(
          accountId: accountId,
          event: applyRsvp(cached, MeetingInviteResponseType.decline),
        ),
      );
    }

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

  @override
  Future<Either<Failure, List<AttendeeAvailability>>> checkAttendeesAvailability({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
    String? organizerEmail,
    String? accountId,
    String? excludeEventId,
    DateTime? excludeStart,
    DateTime? excludeEnd,
  }) async {
    final ds = _availabilityDatasource(accountId);
    if (ds == null) return const Right([]);

    try {
      final results = <AttendeeAvailability>[];

      // Query the whole working day rather than just the meeting window: the
      // schedule pane draws 07:00–20:00 so the organizer can find a free slot,
      // and it can only show blocks that were actually fetched. Widened past
      // those bounds when the meeting itself falls outside them, so a 06:00 or
      // 21:00 meeting still gets its own window covered.
      final dayStart = DateTime(start.year, start.month, start.day, 7);
      final dayEnd = DateTime(start.year, start.month, start.day, 20);
      final windowStart = start.isBefore(dayStart) ? start : dayStart;
      final windowEnd = end.isAfter(dayEnd) ? end : dayEnd;

      // Organiser: fetch full calendar events so subjects are included.
      // getSchedule redacts subjects for most queries; calendarView does not.
      if (organizerEmail != null) {
        final events = await ds.getCalendarEvents(
          startDateTime: windowStart,
          endDateTime: windowEnd,
        );
        final items = events
            .where((e) => !e.isAllDay && e.status != CalendarEventStatus.free)
            // The organizer's own copy is matched by id, which is exact — this
            // path fetches whole events, unlike the attendee free/busy below.
            .where((e) => !_isExcludedEvent(e, excludeEventId))
            .map((e) => AttendeeScheduleItem(
                  start: e.start,
                  end: e.end,
                  status: _mapStatus(e.status),
                  subject: e.subject,
                ))
            .toList();
        results.add(AttendeeAvailability(
          email: organizerEmail,
          status: _worstOverlap(items, start, end),
          scheduleItems: items,
        ));
      }

      // Attendees: use getSchedule for free/busy (subjects not reliably returned).
      final attendeeEmails =
          emails.where((e) => e != organizerEmail).toList();
      if (attendeeEmails.isNotEmpty) {
        final schedules = await ds.getAttendeesSchedule(
          emails: attendeeEmails,
          start: windowStart,
          end: windowEnd,
        );
        for (final raw in schedules) {
          results.add(_statusForMeetingWindow(
            _withoutExcludedMeeting(raw, excludeStart, excludeEnd),
            start,
            end,
            // Read from the untrimmed response on purpose — see the doc comment.
            hadBlocks: raw.scheduleItems.isNotEmpty,
          ));
        }
      }

      return Right(results);
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

  /// Narrows a datasource's day-wide summary status down to the meeting itself.
  ///
  /// Datasources derive their status from whatever window they were asked
  /// about, which is now the whole working day (the schedule pane needs those
  /// blocks), so a guest with a busy afternoon would otherwise be flagged as a
  /// clash for a free-morning meeting.
  ///
  /// [hadBlocks] is whether the provider returned any detail blocks *before*
  /// the meeting being edited was discounted, and cannot be re-derived from
  /// `a.scheduleItems` here: a guest whose only commitment was this very
  /// meeting arrives with an empty list and has to read Free, rather than
  /// falling through to the provider's now-stale day-wide status.
  AttendeeAvailability _statusForMeetingWindow(
    AttendeeAvailability a,
    DateTime start,
    DateTime end, {
    required bool hadBlocks,
  }) {
    // `unknown` means this mailbox's free/busy is not visible to us. Having
    // no blocks for that reason must never be reported as Free.
    if (a.status == AttendeeAvailabilityStatus.unknown) return a;

    // Blocks present — recompute precisely from the ones that overlap.
    if (hadBlocks) {
      return AttendeeAvailability(
        email: a.email,
        status: _worstOverlap(a.scheduleItems, start, end),
        scheduleItems: a.scheduleItems,
      );
    }

    // No blocks, but a status the provider was willing to state: Exchange
    // discloses free/busy without details for guests who share only that
    // much, so the day-wide status is all we have. Keep it — over-reporting
    // a clash is safer than claiming a guest is free when they are not.
    return a;
  }

  /// True when [e] is the meeting currently being edited.
  ///
  /// Matches the series master too, so editing a whole recurring series
  /// discounts every occurrence of it rather than just the one that was opened.
  bool _isExcludedEvent(CalendarEvent e, String? excludeEventId) {
    if (excludeEventId == null) return false;
    return e.id == excludeEventId || e.seriesMasterId == excludeEventId;
  }

  /// Drops a guest's own copy of the meeting being edited.
  ///
  /// Free/busy carries no event id — Graph's `getSchedule` and Google's
  /// `freeBusy` both report anonymous intervals — so the meeting's stored slot
  /// is the only thing left to match on. Bounds are compared with a minute of
  /// slack because providers round these times to the second.
  ///
  /// Google merges touching busy intervals, so a guest with something butted up
  /// against this meeting comes back as one wider block that no longer matches
  /// and is therefore kept. That over-reports a clash rather than concealing
  /// one, which is the right direction to be wrong in.
  AttendeeAvailability _withoutExcludedMeeting(
    AttendeeAvailability a,
    DateTime? excludeStart,
    DateTime? excludeEnd,
  ) {
    if (excludeStart == null || excludeEnd == null) return a;
    if (a.scheduleItems.isEmpty) return a;

    final kept = a.scheduleItems
        .where((i) => !_isSameSlot(i, excludeStart, excludeEnd))
        .toList();
    if (kept.length == a.scheduleItems.length) return a;

    return AttendeeAvailability(
      email: a.email,
      status: a.status,
      scheduleItems: kept,
    );
  }

  static const _slotSlack = Duration(seconds: 60);

  bool _isSameSlot(AttendeeScheduleItem i, DateTime start, DateTime end) =>
      i.start.difference(start.toUtc()).abs() <= _slotSlack &&
      i.end.difference(end.toUtc()).abs() <= _slotSlack;

  /// Calendar datasource to answer a free/busy query for [accountId].
  ///
  /// The active account's shared datasource is reused whenever it is the one
  /// being asked about, because [AccountManager.buildCalendarDatasourceForAccount]
  /// stands up an independent auth pipeline against the same stored token —
  /// running that alongside the active one races on refresh (see
  /// CalendarReminderService._reconcileAccount for the same trade-off).
  CalendarRemoteDatasource? _availabilityDatasource(String? accountId) {
    if (accountId == null || accountId == _accountManager.activeAccount?.id) {
      return _accountManager.calendarDatasource;
    }
    final account = _accountManager.accountById(accountId);
    if (account == null) return _accountManager.calendarDatasource;
    return _accountManager.buildCalendarDatasourceForAccount(account);
  }

  AttendeeAvailabilityStatus _mapStatus(CalendarEventStatus s) => switch (s) {
        CalendarEventStatus.free => AttendeeAvailabilityStatus.free,
        CalendarEventStatus.tentative => AttendeeAvailabilityStatus.tentative,
        CalendarEventStatus.outOfOffice => AttendeeAvailabilityStatus.outOfOffice,
        CalendarEventStatus.workingElsewhere =>
          AttendeeAvailabilityStatus.workingElsewhere,
        CalendarEventStatus.busy => AttendeeAvailabilityStatus.busy,
      };

  AttendeeAvailabilityStatus _worstOverlap(
      List<AttendeeScheduleItem> items, DateTime start, DateTime end) {
    final overlapping = items.where(
      (i) => i.start.isBefore(end) && i.end.isAfter(start),
    );
    if (overlapping.any((i) =>
        i.status == AttendeeAvailabilityStatus.busy ||
        i.status == AttendeeAvailabilityStatus.outOfOffice)) {
      return AttendeeAvailabilityStatus.busy;
    }
    if (overlapping.any((i) => i.status == AttendeeAvailabilityStatus.tentative)) {
      return AttendeeAvailabilityStatus.tentative;
    }
    if (overlapping.any(
        (i) => i.status == AttendeeAvailabilityStatus.workingElsewhere)) {
      return AttendeeAvailabilityStatus.workingElsewhere;
    }
    return AttendeeAvailabilityStatus.free;
  }
}
