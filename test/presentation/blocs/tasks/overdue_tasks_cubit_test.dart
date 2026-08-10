// The count behind the red dot on the folder panel's Tasks icon.
//
// Persistence is the real AppDatabase on an in-memory NativeDatabase — the
// scheduled_task_reminders rows *are* the data source, so mocking them out
// would leave nothing under test. TaskReminderService is real too, so the
// change signal that makes a completed task clear the dot is exercised end to
// end rather than stubbed.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/infrastructure/notifications/task_reminder_service.dart';
import 'package:nightmail/presentation/blocs/tasks/overdue_tasks_cubit.dart';

import 'overdue_tasks_cubit_test.mocks.dart';

@GenerateMocks([AccountManager, NotificationService])
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
  late TaskReminderService reminders;
  late OverdueTasksCubit cubit;

  final today = DateTime.now();

  /// A due date as the providers store it: midnight UTC on a calendar day.
  int dueDaysFromToday(int days) =>
      DateTime.utc(today.year, today.month, today.day + days)
          .millisecondsSinceEpoch;

  Future<void> addRow(String taskId, int dueAtMs,
          {String accountId = 'acct-1'}) =>
      db.upsertScheduledTaskReminder(
        accountId: accountId,
        listId: 'list-1',
        taskId: taskId,
        triggerAtMs: dueAtMs,
        dueAtMs: dueAtMs,
        osScheduled: false,
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    accountManager = MockAccountManager();
    notifications = MockNotificationService();

    when(accountManager.accounts).thenReturn([account]);
    when(accountManager.activeAccount).thenReturn(account);
    when(notifications.cancelTaskReminder(
      accountId: anyNamed('accountId'),
      taskId: anyNamed('taskId'),
    )).thenAnswer((_) async {});

    reminders = TaskReminderService(
      accountManager: accountManager,
      notificationService: notifications,
      database: db,
    );
    cubit = OverdueTasksCubit(
      accountManager: accountManager,
      database: db,
      reminders: reminders,
    );
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  test('counts only the tasks whose due day has already passed', () async {
    await addRow('overdue-1', dueDaysFromToday(-1));
    await addRow('overdue-2', dueDaysFromToday(-9));
    await addRow('due-today', dueDaysFromToday(0));
    await addRow('due-later', dueDaysFromToday(3));

    await cubit.refresh();

    expect(cubit.state, 2);
  });

  test('ignores other accounts — the icon opens the active one', () async {
    await addRow('mine', dueDaysFromToday(-1));
    await addRow('theirs', dueDaysFromToday(-1), accountId: 'acct-2');

    await cubit.refresh();

    expect(cubit.state, 1);
  });

  test('is zero with no account signed in', () async {
    await addRow('overdue-1', dueDaysFromToday(-1));
    when(accountManager.activeAccount).thenReturn(null);

    await cubit.refresh();

    expect(cubit.state, 0);
  });

  test('re-counts when the reminder service drops a row', () async {
    await addRow('overdue-1', dueDaysFromToday(-1));
    await addRow('overdue-2', dueDaysFromToday(-2));
    cubit.start();
    await pumpEventQueue();
    expect(cubit.state, 2);

    // What ticking a task off in the pane does.
    await reminders.dismissTask('overdue-1');
    await pumpEventQueue();

    expect(cubit.state, 1);
  });
}
