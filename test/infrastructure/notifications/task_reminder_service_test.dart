// Reconciliation behaviour of TaskReminderService: which tasks get a due
// notification, when it is scheduled vs raised immediately, and — the part
// worth the most cover — that a task falling due while the app was closed is
// announced exactly once rather than never or on every cycle.
//
// The datasource layer is mocked (mockito, per the repo convention) but the
// persistence is the real AppDatabase on an in-memory NativeDatabase, since
// the notified-once guarantee lives in those rows.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/remote/tasks_remote_datasource.dart';
import 'package:nightmail/data/models/todo_task_list_model.dart';
import 'package:nightmail/data/models/todo_task_model.dart';
import 'package:nightmail/domain/entities/todo_task.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/infrastructure/notifications/task_reminder_service.dart';

import 'task_reminder_service_test.mocks.dart';

@GenerateMocks([AccountManager, NotificationService, TasksRemoteDatasource])
void main() {
  const account = MicrosoftAccount(
    id: 'acct-1',
    displayName: 'Work',
    emailAddress: 'test@example.com',
    tenantId: 'common',
  );

  late AppDatabase db;
  late MockAccountManager accountManager;
  late MockNotificationService notifications;
  late MockTasksRemoteDatasource tasksDatasource;
  late TaskReminderService service;

  TodoTaskModel task(
    String id, {
    DateTime? due,
    String listId = 'list-1',
    TodoTaskStatus status = TodoTaskStatus.notStarted,
  }) =>
      TodoTaskModel(
        id: id,
        listId: listId,
        title: 'Task $id',
        status: status,
        dueDateTime: due,
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    accountManager = MockAccountManager();
    notifications = MockNotificationService();
    tasksDatasource = MockTasksRemoteDatasource();

    when(accountManager.accounts).thenReturn([account]);
    when(accountManager.activeAccount).thenReturn(account);
    when(accountManager.tasksDatasource).thenReturn(tasksDatasource);
    when(tasksDatasource.getTaskLists()).thenAnswer(
      (_) async => [const TodoTaskListModel(id: 'list-1', displayName: 'Tasks')],
    );

    when(notifications.osRetainsSchedule).thenReturn(true);
    when(notifications.scheduleTaskReminder(
      accountId: anyNamed('accountId'),
      listId: anyNamed('listId'),
      taskId: anyNamed('taskId'),
      title: anyNamed('title'),
      body: anyNamed('body'),
      triggerUtc: anyNamed('triggerUtc'),
    )).thenAnswer((_) async {});
    when(notifications.showTaskDueNotification(
      accountId: anyNamed('accountId'),
      listId: anyNamed('listId'),
      taskId: anyNamed('taskId'),
      title: anyNamed('title'),
      body: anyNamed('body'),
    )).thenAnswer((_) async {});
    when(notifications.cancelTaskReminder(
      accountId: anyNamed('accountId'),
      taskId: anyNamed('taskId'),
    )).thenAnswer((_) async {});
    when(notifications.showTasksDueSummaryNotification(
      accountId: anyNamed('accountId'),
      count: anyNamed('count'),
      accountLabel: anyNamed('accountLabel'),
    )).thenAnswer((_) async {});

    service = TaskReminderService(
      accountManager: accountManager,
      notificationService: notifications,
      database: db,
    );
  });

  tearDown(() async {
    await db.close();
  });

  void stubTasks(List<TodoTaskModel> tasks) {
    when(tasksDatasource.getTasks(any, includeCompleted: anyNamed('includeCompleted')))
        .thenAnswer((_) async => tasks);
  }

  group('triggerFor', () {
    test('a date-only due date fires at 9am local on the intended day', () {
      // Both providers hand back the due *date* as midnight UTC.
      final due = DateTime.utc(2026, 8, 3).toLocal();
      final trigger = TaskReminderService.triggerFor(task('t', due: due))!;

      expect(trigger, DateTime(2026, 8, 3, 9));
    });

    test('a due date with a time of day is used as-is', () {
      final due = DateTime(2026, 8, 3, 16, 30);
      expect(TaskReminderService.triggerFor(task('t', due: due)), due);
    });

    test('an explicit reminder wins over the due date', () {
      final reminder = DateTime(2026, 8, 1, 7);
      final t = TodoTaskModel(
        id: 't',
        listId: 'list-1',
        title: 'Task',
        dueDateTime: DateTime(2026, 8, 3, 16, 30),
        isReminderOn: true,
        reminderDateTime: reminder,
      );
      expect(TaskReminderService.triggerFor(t), reminder);
    });

    test('a reminder that is switched off is ignored', () {
      final t = TodoTaskModel(
        id: 't',
        listId: 'list-1',
        title: 'Task',
        dueDateTime: DateTime(2026, 8, 3, 16, 30),
        reminderDateTime: DateTime(2026, 8, 1, 7),
      );
      expect(TaskReminderService.triggerFor(t), DateTime(2026, 8, 3, 16, 30));
    });

    test('completed and undated tasks never trigger', () {
      expect(TaskReminderService.triggerFor(task('t')), isNull);
      expect(
        TaskReminderService.triggerFor(task(
          't',
          due: DateTime(2026, 8, 3, 16, 30),
          status: TodoTaskStatus.completed,
        )),
        isNull,
      );
    });
  });

  group('reconcileAll', () {
    test('schedules a task due in the future without alerting now', () async {
      final due = DateTime.now().add(const Duration(days: 2));
      stubTasks([task('t1', due: due)]);

      await service.reconcileAll();

      verify(notifications.scheduleTaskReminder(
        accountId: 'acct-1',
        listId: 'list-1',
        taskId: 't1',
        title: 'Task t1',
        body: anyNamed('body'),
        triggerUtc: anyNamed('triggerUtc'),
      )).called(1);
      verifyNever(notifications.showTaskDueNotification(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
      ));

      final rows = await db.getScheduledTaskReminders('acct-1');
      expect(rows.single.osScheduled, isTrue);
      expect(rows.single.notifiedAtMs, isNull);
    });

    test('alerts immediately for a task that is already due', () async {
      stubTasks([task('t1', due: DateTime.now().subtract(const Duration(days: 1)))]);

      await service.reconcileAll();

      final captured = verify(notifications.showTaskDueNotification(
        accountId: 'acct-1',
        listId: 'list-1',
        taskId: 't1',
        title: 'Task t1',
        body: captureAnyNamed('body'),
      )).captured.single as String;
      expect(captured, contains('Overdue'));
      expect(
          (await db.getScheduledTaskReminders('acct-1')).single.notifiedAtMs,
          isNotNull);
    });

    test('does not re-alert an overdue task on the next cycle', () async {
      stubTasks([task('t1', due: DateTime.now().subtract(const Duration(days: 1)))]);

      await service.reconcileAll();
      await service.reconcileAll();
      await service.reconcileAll();

      verify(notifications.showTaskDueNotification(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
      )).called(1);
    });

    test(
        'trusts the OS to have delivered a scheduled alert whose time has passed',
        () async {
      // Row left behind by an earlier cycle: handed to an OS scheduler that
      // outlives the app, trigger since elapsed, never explicitly notified.
      final elapsed = DateTime.now().subtract(const Duration(hours: 3));
      await db.upsertScheduledTaskReminder(
        accountId: 'acct-1',
        listId: 'list-1',
        taskId: 't1',
        triggerAtMs: elapsed.millisecondsSinceEpoch,
        dueAtMs: elapsed.millisecondsSinceEpoch,
        osScheduled: true,
      );
      stubTasks([task('t1', due: elapsed)]);

      await service.reconcileAll();

      verifyNever(notifications.showTaskDueNotification(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
      ));
      expect(
          (await db.getScheduledTaskReminders('acct-1')).single.notifiedAtMs,
          isNotNull);
    });

    test(
        'raises the alert itself when the schedule did not survive the restart',
        () async {
      // Same row, but on a platform whose timer died with the process (Linux).
      when(notifications.osRetainsSchedule).thenReturn(false);
      final elapsed = DateTime.now().subtract(const Duration(hours: 3));
      await db.upsertScheduledTaskReminder(
        accountId: 'acct-1',
        listId: 'list-1',
        taskId: 't1',
        triggerAtMs: elapsed.millisecondsSinceEpoch,
        dueAtMs: elapsed.millisecondsSinceEpoch,
        osScheduled: false,
      );
      stubTasks([task('t1', due: elapsed)]);

      await service.reconcileAll();

      verify(notifications.showTaskDueNotification(
        accountId: 'acct-1',
        listId: 'list-1',
        taskId: 't1',
        title: 'Task t1',
        body: anyNamed('body'),
      )).called(1);
    });

    test('reschedules when the due date moves', () async {
      final firstDue = DateTime.now().add(const Duration(days: 2));
      stubTasks([task('t1', due: firstDue)]);
      await service.reconcileAll();

      final movedDue = DateTime.now().add(const Duration(days: 5));
      stubTasks([task('t1', due: movedDue)]);
      await service.reconcileAll();

      verify(notifications.cancelTaskReminder(accountId: 'acct-1', taskId: 't1'))
          .called(1);
      verify(notifications.scheduleTaskReminder(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: 't1',
        title: anyNamed('title'),
        body: anyNamed('body'),
        triggerUtc: anyNamed('triggerUtc'),
      )).called(2);
    });

    test('cancels and forgets a task that is completed or deleted', () async {
      stubTasks([task('t1', due: DateTime.now().add(const Duration(days: 2)))]);
      await service.reconcileAll();

      // getTasks(includeCompleted: false) stops returning it.
      stubTasks([]);
      await service.reconcileAll();

      verify(notifications.cancelTaskReminder(accountId: 'acct-1', taskId: 't1'))
          .called(1);
      expect(await db.getScheduledTaskReminders('acct-1'), isEmpty);
    });

    test('collapses a backlog into one summary instead of a wall of banners',
        () async {
      final due = DateTime.now().subtract(const Duration(hours: 5));
      stubTasks([for (var i = 0; i < 6; i++) task('t$i', due: due)]);

      await service.reconcileAll();

      verify(notifications.showTasksDueSummaryNotification(
        accountId: 'acct-1',
        count: 6,
        accountLabel: 'Work',
      )).called(1);
      verifyNever(notifications.showTaskDueNotification(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
      ));
      // All six are still recorded as announced, so the summary isn't repeated.
      final rows = await db.getScheduledTaskReminders('acct-1');
      expect(rows, hasLength(6));
      expect(rows.every((r) => r.notifiedAtMs != null), isTrue);
    });

    test('records long-overdue tasks silently rather than alerting', () async {
      stubTasks([
        task('old', due: DateTime.now().subtract(const Duration(days: 10))),
      ]);

      await service.reconcileAll();

      verifyNever(notifications.showTaskDueNotification(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
      ));
      verifyNever(notifications.showTasksDueSummaryNotification(
        accountId: anyNamed('accountId'),
        count: anyNamed('count'),
        accountLabel: anyNamed('accountLabel'),
      ));
      expect(
          (await db.getScheduledTaskReminders('acct-1')).single.notifiedAtMs,
          isNotNull);
    });

    test('leaves tasks beyond the lookahead window alone', () async {
      stubTasks([task('t1', due: DateTime.now().add(const Duration(days: 30)))]);

      await service.reconcileAll();

      verifyNever(notifications.scheduleTaskReminder(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
        triggerUtc: anyNamed('triggerUtc'),
      ));
      expect(await db.getScheduledTaskReminders('acct-1'), isEmpty);
    });

    test('a failing account does not stop the others', () async {
      const other = MicrosoftAccount(
        id: 'acct-2',
        displayName: 'Personal',
        emailAddress: 'other@example.com',
        tenantId: 'common',
      );
      final otherDatasource = MockTasksRemoteDatasource();
      when(accountManager.accounts).thenReturn([account, other]);
      when(accountManager.buildTasksDatasourceForAccount(other))
          .thenReturn(otherDatasource);
      when(otherDatasource.getTaskLists()).thenAnswer(
        (_) async =>
            [const TodoTaskListModel(id: 'list-9', displayName: 'Tasks')],
      );
      when(otherDatasource.getTasks(any,
              includeCompleted: anyNamed('includeCompleted')))
          .thenAnswer((_) async =>
              [task('t9', listId: 'list-9', due: DateTime.now().add(const Duration(days: 1)))]);

      when(tasksDatasource.getTaskLists()).thenThrow(Exception('auth expired'));

      await service.reconcileAll();

      verify(notifications.scheduleTaskReminder(
        accountId: 'acct-2',
        listId: 'list-9',
        taskId: 't9',
        title: anyNamed('title'),
        body: anyNamed('body'),
        triggerUtc: anyNamed('triggerUtc'),
      )).called(1);
    });

    test('skips accounts with no tasks provider', () async {
      const imap = ImapAccount(
        id: 'acct-imap',
        displayName: 'IMAP',
        emailAddress: 'imap@example.com',
        host: 'mail.example.com',
        port: 993,
        useSsl: true,
        smtpHost: 'smtp.example.com',
        smtpPort: 587,
        smtpUseSsl: false,
      );
      when(accountManager.accounts).thenReturn([imap]);
      when(accountManager.activeAccount).thenReturn(null);
      when(accountManager.buildTasksDatasourceForAccount(imap)).thenReturn(null);

      await service.reconcileAll();

      verifyNever(notifications.scheduleTaskReminder(
        accountId: anyNamed('accountId'),
        listId: anyNamed('listId'),
        taskId: anyNamed('taskId'),
        title: anyNamed('title'),
        body: anyNamed('body'),
        triggerUtc: anyNamed('triggerUtc'),
      ));
    });
  });

  group('dismissTask', () {
    test('cancels the pending alert and forgets the row', () async {
      stubTasks([task('t1', due: DateTime.now().add(const Duration(days: 2)))]);
      await service.reconcileAll();

      await service.dismissTask('t1');

      verify(notifications.cancelTaskReminder(accountId: 'acct-1', taskId: 't1'))
          .called(1);
      expect(await db.getScheduledTaskReminders('acct-1'), isEmpty);
    });
  });

  group('clearAccount', () {
    test('cancels every pending reminder and drops the rows', () async {
      stubTasks([
        task('t1', due: DateTime.now().add(const Duration(days: 1))),
        task('t2', due: DateTime.now().add(const Duration(days: 2))),
      ]);
      await service.reconcileAll();

      await service.clearAccount('acct-1');

      verify(notifications.cancelTaskReminder(accountId: 'acct-1', taskId: 't1'))
          .called(1);
      verify(notifications.cancelTaskReminder(accountId: 'acct-1', taskId: 't2'))
          .called(1);
      expect(await db.getScheduledTaskReminders('acct-1'), isEmpty);
    });
  });
}
