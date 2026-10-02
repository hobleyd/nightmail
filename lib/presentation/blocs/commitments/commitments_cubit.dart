import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/inbox_folder.dart';
import '../../../core/utils/outgoing_folder.dart';
import '../../../core/utils/task_due.dart';
import '../../../data/datasources/local/task_reminder_schedule_local_datasource.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/repositories/commitment_repository.dart';
import '../../../domain/repositories/email_repository.dart';
import '../../../domain/usecases/commitments/detect_commitments.dart';
import '../../../domain/usecases/get_cached_calendar_events.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'commitments_state.dart';

/// Drives the Commitments pane for the active account.
///
/// Everything it shows comes from the local cache: the ledger rows, the
/// account's cached Sent and Inbox listings (what the model is asked about),
/// today's cached calendar events and the task-reminder rows. The only
/// network it causes is the model's own calls, made through
/// [DetectCommitments] — one per unscanned message, capped per scan.
///
/// [load] paints the ledger on disk at once and then runs a scan in the
/// background; [scan] is the explicit refresh and what the pane calls when a
/// poll cycle brings new mail.
class CommitmentsCubit extends Cubit<CommitmentsState> {
  CommitmentsCubit({
    required AccountManager accountManager,
    required EmailRepository emailRepository,
    required CommitmentRepository commitmentRepository,
    required DetectCommitments detectCommitments,
    required GetCachedCalendarEvents getCachedCalendarEvents,
    required TaskReminderScheduleLocalDatasource taskReminders,
    DateTime Function()? now,
  })  : _accounts = accountManager,
        _emails = emailRepository,
        _ledger = commitmentRepository,
        _detect = detectCommitments,
        _calendar = getCachedCalendarEvents,
        _taskReminders = taskReminders, // ignore: prefer_initializing_formals
        _now = now ?? DateTime.now,
        super(const CommitmentsState());

  final AccountManager _accounts;
  final EmailRepository _emails;
  final CommitmentRepository _ledger;
  final DetectCommitments _detect;
  final GetCachedCalendarEvents _calendar;
  final TaskReminderScheduleLocalDatasource _taskReminders;
  final DateTime Function() _now;

  /// How much of each folder's cached listing the scan considers.
  static const int recentMailWindow = 60;

  /// Guards against overlapping scans (a poll cycle landing mid-refresh).
  Future<void>? _inFlightScan;

  /// Paints the cached ledger and today's context for the active account,
  /// then scans new mail in the background.
  Future<void> load() async {
    final account = _accounts.activeAccount;
    if (account == null) {
      emit(const CommitmentsState(
        status: CommitmentsStatus.error,
        message: 'Sign in to an account to track commitments.',
      ));
      return;
    }
    emit(state.copyWith(
      status: CommitmentsStatus.loading,
      accountId: account.id,
      message: null,
    ));

    final ledger = await _ledger.getCommitments(accountId: account.id);
    if (isClosed) return;
    final today = await _todayContext(account.id);
    if (isClosed) return;

    ledger.fold(
      (failure) => emit(state.copyWith(
        status: CommitmentsStatus.error,
        message: failure.message,
      )),
      (commitments) => emit(state.copyWith(
        status: CommitmentsStatus.loaded,
        commitments: commitments,
        todayEvents: today.events,
        tasksDueToday: today.tasksDue,
      )),
    );
    if (state.status == CommitmentsStatus.loaded) unawaited(scan());
  }

  /// Shows the model whatever Sent/Inbox mail it has not seen, closes what the
  /// mail has since settled, and refreshes today's context. Safe to call
  /// repeatedly; a call during a scan joins it.
  Future<void> scan() {
    return _inFlightScan ??= _doScan().whenComplete(() => _inFlightScan = null);
  }

  Future<void> _doScan() async {
    final account = _accounts.activeAccount;
    if (account == null || isClosed) return;
    if (state.accountId != account.id) {
      // The active account changed under us: start over for the new one.
      await load();
      return;
    }
    emit(state.copyWith(status: CommitmentsStatus.scanning, message: null));

    final mail = await _recentMail(account.id);
    if (isClosed) return;

    final result = await _detect(DetectCommitmentsParams(
      accountId: account.id,
      selfAddresses: {account.emailAddress.toLowerCase()},
      sentEmails: mail.sent,
      inboxEmails: mail.inbox,
      now: _now(),
    ));
    if (isClosed) return;

    final scanned = await _ledger.getScannedEmailIds(accountId: account.id);
    final inboxScanned = scanned.fold(
      (_) => state.inboxScanned,
      (ids) => mail.inbox.where((e) => ids.contains(e.id)).length,
    );
    final today = await _todayContext(account.id);
    if (isClosed) return;

    result.fold(
      (failure) {
        final noRoute = failure is NoProviderConfigured;
        emit(state.copyWith(
          // With a ledger already on screen a failed refresh is a message,
          // not a blank pane.
          status: state.commitments.isEmpty && !noRoute
              ? CommitmentsStatus.error
              : CommitmentsStatus.loaded,
          needsTriageRoute: noRoute,
          message: failure.message,
          todayEvents: today.events,
          tasksDueToday: today.tasksDue,
          inboxScanned: inboxScanned,
        ));
      },
      (r) {
        emit(state.copyWith(
          status: CommitmentsStatus.loaded,
          commitments: r.commitments,
          needsTriageRoute: false,
          message: r.warning,
          lastScanAt: _now(),
          lastClassified: r.classified,
          remaining: r.remaining,
          todayEvents: today.events,
          tasksDueToday: today.tasksDue,
          inboxScanned: inboxScanned,
        ));
      },
    );
  }

  Future<void> markDone(String id) => _setStatus(id, CommitmentStatus.done);

  Future<void> dismiss(String id) => _setStatus(id, CommitmentStatus.dismissed);

  Future<void> reopen(String id) => _setStatus(id, CommitmentStatus.open);

  Future<void> _setStatus(String id, CommitmentStatus status) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final now = _now();
    final result = await _ledger.setStatus(
      accountId: accountId,
      id: id,
      status: status,
      now: now,
    );
    if (isClosed) return;
    result.fold(
      (failure) => emit(state.copyWith(message: failure.message)),
      (_) => emit(state.copyWith(
        commitments: [
          for (final c in state.commitments)
            c.id == id
                ? c.copyWith(
                    status: status,
                    resolvedAt: status == CommitmentStatus.open ? null : now,
                    clearResolvedAt: status == CommitmentStatus.open,
                  )
                : c,
        ],
      )),
    );
  }

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  /// The newest [recentMailWindow] cached messages of the account's Sent and
  /// Inbox folders, found by well-known id or display name in the folder
  /// cache. A folder that cannot be found contributes nothing — the scan runs
  /// on whichever side is available.
  Future<({List<Email> sent, List<Email> inbox})> _recentMail(
    String accountId,
  ) async {
    final folders = (await _emails.getCachedFolders(accountId))
        .getOrElse((_) => const []);
    final sentMatches = folders.where(isSentMailFolder);
    final inboxMatches = folders.where(isInboxFolder);
    final sentFolder = sentMatches.isEmpty ? null : sentMatches.first;
    final inboxFolder = inboxMatches.isEmpty ? null : inboxMatches.first;

    Future<List<Email>> recent(String? folderId) async {
      if (folderId == null) return const [];
      final emails = (await _emails.getCachedEmails(
        accountId: accountId,
        folderId: folderId,
      ))
          .getOrElse((_) => const []);
      // The cache is ordered newest first already; make sure of it.
      final sorted = List<Email>.of(emails)
        ..sort((a, b) => (b.sentDateTime ?? b.receivedDateTime)
            .compareTo(a.sentDateTime ?? a.receivedDateTime));
      return sorted.take(recentMailWindow).toList();
    }

    return (
      sent: await recent(sentFolder?.id),
      inbox: await recent(inboxFolder?.id),
    );
  }

  /// Today's events (from the calendar cache) and the count of open tasks due
  /// today (from the task-reminder rows, which cover every list).
  Future<({List<CalendarEvent> events, int tasksDue})> _todayContext(
    String accountId,
  ) async {
    final now = _now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1));

    final events = (await _calendar(GetCalendarEventsParams(
      startDateTime: start,
      endDateTime: end,
      accountId: accountId,
    )))
        .getOrElse((_) => const []);
    final sorted = List.of(events)..sort((a, b) => a.start.compareTo(b.start));

    var tasksDue = 0;
    try {
      final rows = await _taskReminders.getScheduledTaskReminders(accountId);
      tasksDue = rows
          .where((r) =>
              taskDueDay(DateTime.fromMillisecondsSinceEpoch(r.dueAtMs)) ==
              start)
          .length;
    } catch (e) {
      debugPrint('CommitmentsCubit: task reminder rows unavailable: $e');
    }
    return (events: sorted, tasksDue: tasksDue);
  }
}
