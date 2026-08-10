import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/task_due.dart';
import '../../../data/datasources/local/task_reminder_schedule_local_datasource.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/notifications/task_reminder_service.dart';

/// How many of the active account's open tasks are already past due — the
/// number behind the red dot on the folder panel's Tasks icon.
///
/// Counted from the `scheduled_task_reminders` rows rather than from
/// [TasksBloc], which holds one list of one account: an overdue item in a list
/// the pane happens not to be showing is still overdue. [TaskReminderService]
/// already walks every list of every account on a 15-minute cycle to arrange
/// due notifications, so the rows are there for free — this reads them and
/// never fetches anything itself.
///
/// Consequences of that source: a task created with a past due date, or one
/// completed in another client, is counted from the next reconcile rather than
/// at once. The app's own completions and due-date edits are immediate, because
/// [TaskReminderService.dismissTask] drops the row and reports it.
class OverdueTasksCubit extends Cubit<int> {
  OverdueTasksCubit({
    required AccountManager accountManager,
    required TaskReminderScheduleLocalDatasource database,
    required TaskReminderService reminders,
  })  : _accountManager = accountManager,
        _database = database,
        _reminders = reminders,
        super(0);

  final AccountManager _accountManager;
  final TaskReminderScheduleLocalDatasource _database;
  final TaskReminderService _reminders;

  /// Re-counts on the hour so a task due today turns red when the day rolls
  /// over. The reminder rows themselves don't move at midnight — the question
  /// asked of them does.
  static const _rolloverInterval = Duration(minutes: 30);

  StreamSubscription<void>? _sub;
  Timer? _rolloverTimer;

  /// Safe to call repeatedly — HomePage calls it on every build.
  void start() {
    _sub ??= _reminders.changes.listen((_) => refresh());
    _rolloverTimer ??= Timer.periodic(_rolloverInterval, (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) {
      if (!isClosed) emit(0);
      return;
    }
    final rows = await _database.getScheduledTaskReminders(accountId);
    final count = rows
        .where((r) =>
            isTaskOverdue(DateTime.fromMillisecondsSinceEpoch(r.dueAtMs)))
        .length;
    if (!isClosed) emit(count);
  }

  @override
  Future<void> close() {
    _sub?.cancel();
    _rolloverTimer?.cancel();
    return super.close();
  }
}
