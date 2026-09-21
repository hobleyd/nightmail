import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/todo_task.dart';
import 'package:nightmail/domain/entities/todo_task_attachment.dart';
import 'package:nightmail/domain/entities/todo_task_list.dart';
import 'package:nightmail/domain/usecases/attach_email_to_task.dart';
import 'package:nightmail/domain/usecases/create_task.dart';
import 'package:nightmail/domain/usecases/download_task_attachment.dart';
import 'package:nightmail/domain/usecases/get_task_attachments.dart';
import 'package:nightmail/domain/usecases/get_task_lists.dart';
import 'package:nightmail/domain/usecases/get_tasks.dart';
import 'package:nightmail/domain/usecases/update_task_due_date.dart';
import 'package:nightmail/domain/usecases/update_task_status.dart';
import 'package:nightmail/infrastructure/notifications/task_reminder_service.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_bloc.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_event.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_state.dart';

import 'tasks_bloc_test.mocks.dart';

TodoTaskList _list(String id, {bool isDefault = false}) =>
    TodoTaskList(id: id, displayName: 'List $id', isDefault: isDefault);

TodoTask _task(
  String id, {
  String listId = 'list-1',
  TodoTaskStatus status = TodoTaskStatus.notStarted,
  DateTime? due,
  bool hasAttachments = false,
  String title = 'Task',
}) =>
    TodoTask(
      id: id,
      listId: listId,
      title: title,
      status: status,
      dueDateTime: due,
      hasAttachments: hasAttachments,
    );

@GenerateMocks([
  GetTaskLists,
  GetTasks,
  CreateTask,
  UpdateTaskStatus,
  UpdateTaskDueDate,
  AttachEmailToTask,
  GetTaskAttachments,
  DownloadTaskAttachment,
  TaskReminderService,
])
void main() {
  late MockGetTaskLists mockGetTaskLists;
  late MockGetTasks mockGetTasks;
  late MockCreateTask mockCreateTask;
  late MockUpdateTaskStatus mockUpdateTaskStatus;
  late MockUpdateTaskDueDate mockUpdateTaskDueDate;
  late MockAttachEmailToTask mockAttachEmailToTask;
  late MockGetTaskAttachments mockGetTaskAttachments;
  late MockDownloadTaskAttachment mockDownloadTaskAttachment;
  late MockTaskReminderService mockTaskReminders;

  setUp(() {
    provideDummy<Either<Failure, List<TodoTaskList>>>(const Right([]));
    provideDummy<Either<Failure, List<TodoTask>>>(const Right([]));
    provideDummy<Either<Failure, TodoTask>>(Right(_task('x')));
    provideDummy<Either<Failure, List<TodoTaskAttachment>>>(const Right([]));
    provideDummy<Either<Failure, TodoTaskAttachment>>(const Right(
      TodoTaskAttachment(id: 'a', name: 'a.eml', contentType: '', size: 0),
    ));
    provideDummy<Either<Failure, Uint8List>>(Right(Uint8List(0)));

    mockGetTaskLists = MockGetTaskLists();
    mockGetTasks = MockGetTasks();
    mockCreateTask = MockCreateTask();
    mockUpdateTaskStatus = MockUpdateTaskStatus();
    mockUpdateTaskDueDate = MockUpdateTaskDueDate();
    mockAttachEmailToTask = MockAttachEmailToTask();
    mockGetTaskAttachments = MockGetTaskAttachments();
    mockDownloadTaskAttachment = MockDownloadTaskAttachment();
    mockTaskReminders = MockTaskReminderService();

    when(mockTaskReminders.dismissTask(any)).thenAnswer((_) async {});
  });

  TasksBloc makeBloc() => TasksBloc(
        getTaskLists: mockGetTaskLists,
        getTasks: mockGetTasks,
        createTask: mockCreateTask,
        updateTaskStatus: mockUpdateTaskStatus,
        updateTaskDueDate: mockUpdateTaskDueDate,
        attachEmailToTask: mockAttachEmailToTask,
        getTaskAttachments: mockGetTaskAttachments,
        downloadTaskAttachment: mockDownloadTaskAttachment,
        taskReminders: mockTaskReminders,
      );

  /// Drives the bloc into TasksLoaded via a real TasksLoadRequested, then
  /// clears mock call history so each test's own verifies start clean.
  Future<TasksBloc> loadedBloc({
    List<TodoTaskList> lists = const [],
    List<TodoTask> tasks = const [],
  }) async {
    when(mockGetTaskLists(any)).thenAnswer((_) async => Right(lists));
    when(mockGetTasks(any)).thenAnswer((_) async => Right(tasks));
    final bloc = makeBloc();
    bloc.add(const TasksLoadRequested());
    await bloc.stream.firstWhere((s) => s is! TasksLoading);
    clearInteractions(mockGetTaskLists);
    clearInteractions(mockGetTasks);
    return bloc;
  }

  group('TasksLoadRequested', () {
    test('loads the default list\'s tasks, moving through Loading to Loaded',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any)).thenAnswer(
          (_) async => Right([_list('list-1'), _list('list-2', isDefault: true)]));
      when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t1')]));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          isA<TasksLoaded>()
              .having((s) => s.selectedListId, 'selectedListId', 'list-2')
              .having((s) => s.tasks.map((t) => t.id), 'task ids', ['t1']),
        ]),
      );
      final params =
          verify(mockGetTasks(captureAny)).captured.single as GetTasksParams;
      expect(params.listId, 'list-2');
    });

    test('falls back to the first list when none is marked default',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any))
          .thenAnswer((_) async => Right([_list('list-1'), _list('list-2')]));
      when(mockGetTasks(any)).thenAnswer((_) async => const Right([]));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          isA<TasksLoaded>()
              .having((s) => s.selectedListId, 'selectedListId', 'list-1'),
        ]),
      );
    });

    test('an empty list of lists loads nothing further', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any)).thenAnswer((_) async => const Right([]));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          isA<TasksLoaded>()
              .having((s) => s.lists, 'lists', isEmpty)
              .having((s) => s.selectedListId, 'selectedListId', ''),
        ]),
      );
      verifyNever(mockGetTasks(any));
    });

    test('a failure fetching lists reports TasksError', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'offline')));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          const TasksError(message: 'offline'),
        ]),
      );
    });

    test('an AuthFailure fetching lists sets requiresReauth', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any))
          .thenAnswer((_) async => const Left(AuthFailure(message: 'expired')));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          const TasksError(message: 'expired', requiresReauth: true),
        ]),
      );
    });

    test('a failure fetching the default list\'s tasks reports TasksError',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any))
          .thenAnswer((_) async => Right([_list('list-1', isDefault: true)]));
      when(mockGetTasks(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'boom')));

      bloc.add(const TasksLoadRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          const TasksError(message: 'boom'),
        ]),
      );
    });
  });

  test('TasksCleared drops everything back to TasksInitial', () async {
    final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
    addTearDown(bloc.close);

    bloc.add(const TasksCleared());

    await expectLater(bloc.stream, emits(const TasksInitial()));
  });

  group('TasksListSelected', () {
    test('optimistically clears the list, then loads the new one\'s tasks',
        () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true), _list('list-2')],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t2')]));

      bloc.add(const TasksListSelected(listId: 'list-2'));

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<TasksLoaded>()
              .having((s) => s.selectedListId, 'selectedListId', 'list-2')
              .having((s) => s.tasks, 'tasks', isEmpty),
          isA<TasksLoaded>()
              .having((s) => s.tasks.map((t) => t.id), 'task ids', ['t2']),
        ]),
      );
    });

    test('clears any focused task', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      bloc.add(const TaskFocusRequested(listId: 'list-1', taskId: 't1'));
      await bloc.stream.first;
      when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t1')]));

      bloc.add(const TasksListSelected(listId: 'list-1'));
      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;

      expect(loaded.focusedTaskId, isNull);
    });

    test('a failure reports TasksError', () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockGetTasks(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'nope')));

      bloc.add(const TasksListSelected(listId: 'list-2'));

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<TasksLoaded>(),
          const TasksError(message: 'nope'),
        ]),
      );
    });

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(const TasksListSelected(listId: 'list-2'));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
      verifyNever(mockGetTasks(any));
    });
  });

  group('TaskFocusRequested', () {
    test('already-loaded task in the current list is just highlighted, no '
        'refetch', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);

      bloc.add(const TaskFocusRequested(listId: 'list-1', taskId: 't1'));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.focusedTaskId, 't1');
      verifyNever(mockGetTasks(any));
      verifyNever(mockGetTaskLists(any));
    });

    test('a task in a different list reuses the already-loaded lists and '
        'fetches that list\'s tasks', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true), _list('list-2')],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t2')]));

      bloc.add(const TaskFocusRequested(listId: 'list-2', taskId: 't2'));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.selectedListId, 'list-2');
      expect(loaded.focusedTaskId, 't2');
      expect(loaded.lists.map((l) => l.id), ['list-1', 'list-2']);
      verifyNever(mockGetTaskLists(any));
    });

    test('a cold start (nothing loaded yet) fetches lists first', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any))
          .thenAnswer((_) async => Right([_list('list-1')]));
      when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t1')]));

      bloc.add(const TaskFocusRequested(listId: 'list-1', taskId: 't1'));

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          isA<TasksLoaded>()
              .having((s) => s.focusedTaskId, 'focusedTaskId', 't1'),
        ]),
      );
    });

    test('a lists fetch failure on cold start reports TasksError', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockGetTaskLists(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'offline')));

      bloc.add(const TaskFocusRequested(listId: 'list-1', taskId: 't1'));

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const TasksLoading(),
          const TasksError(message: 'offline'),
        ]),
      );
      verifyNever(mockGetTasks(any));
    });
  });

  group('TaskStatusToggled', () {
    test('completing a task removes it optimistically and dismisses its '
        'reminder', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1'), _task('t2')],
      );
      addTearDown(bloc.close);
      when(mockUpdateTaskStatus(any))
          .thenAnswer((_) async => Right(_task('t1', status: TodoTaskStatus.completed)));

      bloc.add(const TaskStatusToggled(
        listId: 'list-1',
        taskId: 't1',
        currentStatus: TodoTaskStatus.notStarted,
      ));

      // The optimistic-removal emit lands *before* `dismissTask` is awaited
      // (see _onStatusToggled), so waiting for the emit alone races the
      // dismiss call. Wait for the call that happens after it instead.
      await untilCalled(mockUpdateTaskStatus(any));

      expect((bloc.state as TasksLoaded).tasks.map((t) => t.id), ['t2']);
      verify(mockTaskReminders.dismissTask('t1')).called(1);
      final params = verify(mockUpdateTaskStatus(captureAny)).captured.single
          as UpdateTaskStatusParams;
      expect(params.status, TodoTaskStatus.completed);
    });

    test('re-opening a completed task does not optimistically remove it or '
        'dismiss a reminder', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1', status: TodoTaskStatus.completed)],
      );
      addTearDown(bloc.close);
      when(mockUpdateTaskStatus(any))
          .thenAnswer((_) async => Right(_task('t1')));

      bloc.add(const TaskStatusToggled(
        listId: 'list-1',
        taskId: 't1',
        currentStatus: TodoTaskStatus.completed,
      ));
      await Future<void>.delayed(Duration.zero);

      verifyNever(mockTaskReminders.dismissTask(any));
      final params = verify(mockUpdateTaskStatus(captureAny)).captured.single
          as UpdateTaskStatusParams;
      expect(params.status, TodoTaskStatus.notStarted);
    });

    // Regression test for a real bug this test originally caught:
    // _onStatusToggled's failure branch used to be
    //   result.fold((failure) async { await _getTasks(...); emit(...); }, (_) {})
    // with the whole `result.fold(...)` call never awaited. Since the Left
    // callback was `async` and awaited before its `emit`, that emit fired
    // *after* the bloc had already marked the event handler complete — which
    // the bloc package's Emitter treats as a programming error (`_isCompleted`
    // assertion in package:bloc/src/emitter.dart) and threw. A failed status
    // toggle crashed with an uncaught assertion instead of reverting the
    // optimistic removal. Fixed by awaiting the fold (matching how
    // _onTaskCreated already did it) — see also _onDueDateUpdated below,
    // which had the identical shape and the identical fix.
    test(
      'a failed update reverts by reloading the list\'s tasks',
      () async {
        final bloc = await loadedBloc(
          lists: [_list('list-1', isDefault: true)],
          tasks: [_task('t1')],
        );
        addTearDown(bloc.close);
        when(mockUpdateTaskStatus(any)).thenAnswer(
            (_) async => const Left(ServerFailure(message: 'nope')));
        when(mockGetTasks(any)).thenAnswer((_) async => Right([_task('t1')]));

        bloc.add(const TaskStatusToggled(
          listId: 'list-1',
          taskId: 't1',
          currentStatus: TodoTaskStatus.notStarted,
        ));

        // Optimistically removed, then reverted back once the update fails.
        await expectLater(
          bloc.stream,
          emitsInOrder([
            isA<TasksLoaded>().having((s) => s.tasks, 'tasks', isEmpty),
            isA<TasksLoaded>()
                .having((s) => s.tasks.map((t) => t.id), 'task ids', ['t1']),
          ]),
        );
      },
    );

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(const TaskStatusToggled(
        listId: 'list-1',
        taskId: 't1',
        currentStatus: TodoTaskStatus.notStarted,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
      verifyNever(mockUpdateTaskStatus(any));
    });
  });

  group('TaskCreationRequested', () {
    test('prepends the new task without an email attachment', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockCreateTask(any))
          .thenAnswer((_) async => Right(_task('new-task', title: 'New')));

      bloc.add(const TaskCreationRequested(listId: 'list-1', title: 'New'));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.tasks.map((t) => t.id), containsAll(['t1', 'new-task']));
      verifyNever(mockAttachEmailToTask(any));
    });

    test('attaches the email and marks the task as having an attachment on '
        'success', () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockCreateTask(any)).thenAnswer(
          (_) async => Right(_task('new-task', title: 'From email')));
      when(mockAttachEmailToTask(any)).thenAnswer((_) async => const Right(
            TodoTaskAttachment(
                id: 'a1', name: 'a.eml', contentType: 'message/rfc822', size: 10),
          ));

      bloc.add(const TaskCreationRequested(
        listId: 'list-1',
        title: 'From email',
        emailId: 'email-1',
        emailSubject: 'Re: quarterly report',
      ));

      final states = await bloc.stream
          .where((s) => s is TasksLoaded)
          .cast<TasksLoaded>()
          .take(2)
          .toList();
      // First emit: the bare created task. Second: patched with attachments.
      expect(states[0].tasks.single.hasAttachments, isFalse);
      expect(states[1].tasks.single.hasAttachments, isTrue);

      final params = verify(mockAttachEmailToTask(captureAny)).captured.single
          as AttachEmailToTaskParams;
      expect(params.emailId, 'email-1');
      expect(params.fileName, 'Re_ quarterly report.eml');
    });

    test('sanitises characters that are invalid in a filename', () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockCreateTask(any))
          .thenAnswer((_) async => Right(_task('new-task')));
      when(mockAttachEmailToTask(any)).thenAnswer((_) async => const Right(
            TodoTaskAttachment(id: 'a1', name: 'a.eml', contentType: '', size: 1),
          ));

      bloc.add(const TaskCreationRequested(
        listId: 'list-1',
        title: 'Task',
        emailId: 'email-1',
        emailSubject: 'a/b\\c:d*e?f"g<h>i|j',
      ));
      await bloc.stream.firstWhere(
          (s) => s is TasksLoaded && (s).tasks.single.hasAttachments);

      final params = verify(mockAttachEmailToTask(captureAny)).captured.single
          as AttachEmailToTaskParams;
      expect(params.fileName, 'a_b_c_d_e_f_g_h_i_j.eml');
    });

    test('falls back to the task title when no email subject is given',
        () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockCreateTask(any))
          .thenAnswer((_) async => Right(_task('new-task', title: 'My title')));
      when(mockAttachEmailToTask(any)).thenAnswer((_) async => const Right(
            TodoTaskAttachment(id: 'a1', name: 'a.eml', contentType: '', size: 1),
          ));

      bloc.add(const TaskCreationRequested(
        listId: 'list-1',
        title: 'My title',
        emailId: 'email-1',
      ));
      await bloc.stream.firstWhere(
          (s) => s is TasksLoaded && (s).tasks.single.hasAttachments);

      final params = verify(mockAttachEmailToTask(captureAny)).captured.single
          as AttachEmailToTaskParams;
      expect(params.fileName, 'My title.eml');
    });

    test('an attach failure leaves the created task on screen without '
        'the attachment flag', () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockCreateTask(any))
          .thenAnswer((_) async => Right(_task('new-task')));
      when(mockAttachEmailToTask(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'no attach api')));

      bloc.add(const TaskCreationRequested(
        listId: 'list-1',
        title: 'Task',
        emailId: 'email-1',
      ));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.tasks.single.hasAttachments, isFalse);
    });

    test('a create failure emits nothing', () async {
      final bloc = await loadedBloc(lists: [_list('list-1', isDefault: true)]);
      addTearDown(bloc.close);
      when(mockCreateTask(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'nope')));

      bloc.add(const TaskCreationRequested(listId: 'list-1', title: 'Task'));
      await Future<void>.delayed(Duration.zero);

      expect((bloc.state as TasksLoaded).tasks, isEmpty);
    });

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(const TaskCreationRequested(listId: 'list-1', title: 'Task'));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
      verifyNever(mockCreateTask(any));
    });
  });

  group('TaskDueDateUpdateRequested', () {
    final newDue = DateTime(2026, 5, 1);

    test('optimistically applies the new due date and dismisses the old '
        'reminder', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockUpdateTaskDueDate(any))
          .thenAnswer((_) async => Right(_task('t1', due: newDue)));

      bloc.add(TaskDueDateUpdateRequested(
        listId: 'list-1',
        taskId: 't1',
        dueDate: newDue,
      ));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.tasks.single.dueDateTime, newDue);
      verify(mockTaskReminders.dismissTask('t1')).called(1);
    });

    test('replaces the optimistic task with the server-confirmed one on '
        'success', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockUpdateTaskDueDate(any)).thenAnswer(
          (_) async => Right(_task('t1', due: newDue, hasAttachments: true)));

      bloc.add(TaskDueDateUpdateRequested(
        listId: 'list-1',
        taskId: 't1',
        dueDate: newDue,
      ));

      final states = await bloc.stream
          .where((s) => s is TasksLoaded)
          .cast<TasksLoaded>()
          .take(2)
          .toList();
      expect(states[1].tasks.single.hasAttachments, isTrue);
    });

    // Regression test for the same bug fixed on TaskStatusToggled above:
    // _onDueDateUpdated's revert branch had the identical unawaited-fold
    // shape and the identical fix (awaiting the fold).
    test(
      'reverts by reloading the list\'s tasks on failure',
      () async {
        final bloc = await loadedBloc(
          lists: [_list('list-1', isDefault: true)],
          tasks: [_task('t1')],
        );
        addTearDown(bloc.close);
        when(mockUpdateTaskDueDate(any)).thenAnswer(
            (_) async => const Left(ServerFailure(message: 'nope')));
        when(mockGetTasks(any))
            .thenAnswer((_) async => Right([_task('t1', due: null)]));

        bloc.add(TaskDueDateUpdateRequested(
          listId: 'list-1',
          taskId: 't1',
          dueDate: newDue,
        ));

        final states = await bloc.stream
            .where((s) => s is TasksLoaded)
            .cast<TasksLoaded>()
            .take(2)
            .toList();
        expect(states[0].tasks.single.dueDateTime, newDue); // optimistic
        expect(states[1].tasks.single.dueDateTime, isNull); // reverted
      },
    );

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(TaskDueDateUpdateRequested(
        listId: 'list-1',
        taskId: 't1',
        dueDate: newDue,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
      verifyNever(mockUpdateTaskDueDate(any));
    });
  });

  group('TaskEmailAttachmentTapped', () {
    test('downloads the email attachment and stores its bytes', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTaskAttachments(any)).thenAnswer((_) async => const Right([
            TodoTaskAttachment(
                id: 'other', name: 'x.png', contentType: 'image/png', size: 1),
            TodoTaskAttachment(
                id: 'email',
                name: 'y.eml',
                contentType: 'message/rfc822',
                size: 2),
          ]));
      final bytes = Uint8List.fromList([1, 2, 3]);
      when(mockDownloadTaskAttachment(any))
          .thenAnswer((_) async => Right(bytes));

      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.pendingEmailAttachmentBytes, bytes);
      final params = verify(mockDownloadTaskAttachment(captureAny))
          .captured
          .single as DownloadTaskAttachmentParams;
      expect(params.attachmentId, 'email');
    });

    test('falls back to the first attachment when none is an email',
        () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTaskAttachments(any)).thenAnswer((_) async => const Right([
            TodoTaskAttachment(
                id: 'only', name: 'x.png', contentType: 'image/png', size: 1),
          ]));
      when(mockDownloadTaskAttachment(any))
          .thenAnswer((_) async => Right(Uint8List(0)));

      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));
      await bloc.stream.firstWhere((s) => s is TasksLoaded);

      final params = verify(mockDownloadTaskAttachment(captureAny))
          .captured
          .single as DownloadTaskAttachmentParams;
      expect(params.attachmentId, 'only');
    });

    test('a failure listing attachments emits nothing', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTaskAttachments(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'nope')));

      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));
      await Future<void>.delayed(Duration.zero);

      expect(
          (bloc.state as TasksLoaded).pendingEmailAttachmentBytes, isNull);
      verifyNever(mockDownloadTaskAttachment(any));
    });

    test('a download failure emits nothing', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTaskAttachments(any)).thenAnswer((_) async => const Right([
            TodoTaskAttachment(
                id: 'email',
                name: 'y.eml',
                contentType: 'message/rfc822',
                size: 2),
          ]));
      when(mockDownloadTaskAttachment(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'nope')));

      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));
      await Future<void>.delayed(Duration.zero);

      expect(
          (bloc.state as TasksLoaded).pendingEmailAttachmentBytes, isNull);
    });

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
      verifyNever(mockGetTaskAttachments(any));
    });
  });

  group('TaskAttachmentHandled', () {
    test('clears the pending attachment bytes', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [_task('t1')],
      );
      addTearDown(bloc.close);
      when(mockGetTaskAttachments(any)).thenAnswer((_) async => const Right([
            TodoTaskAttachment(
                id: 'email',
                name: 'y.eml',
                contentType: 'message/rfc822',
                size: 2),
          ]));
      when(mockDownloadTaskAttachment(any))
          .thenAnswer((_) async => Right(Uint8List.fromList([9])));
      bloc.add(const TaskEmailAttachmentTapped(listId: 'list-1', taskId: 't1'));
      await bloc.stream.firstWhere((s) =>
          s is TasksLoaded && s.pendingEmailAttachmentBytes != null);

      bloc.add(const TaskAttachmentHandled());

      final loaded =
          await bloc.stream.firstWhere((s) => s is TasksLoaded) as TasksLoaded;
      expect(loaded.pendingEmailAttachmentBytes, isNull);
    });

    test('does nothing when the pane is not loaded', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);

      bloc.add(const TaskAttachmentHandled());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, const TasksInitial());
    });
  });

  group('TasksLoaded.tasks ordering', () {
    test('sorts by due date, earliest first, undated tasks last', () async {
      final bloc = await loadedBloc(
        lists: [_list('list-1', isDefault: true)],
        tasks: [
          _task('undated'),
          _task('later', due: DateTime(2026, 6, 1)),
          _task('earlier', due: DateTime(2026, 1, 1)),
        ],
      );
      addTearDown(bloc.close);

      expect((bloc.state as TasksLoaded).tasks.map((t) => t.id),
          ['earlier', 'later', 'undated']);
    });
  });
}
