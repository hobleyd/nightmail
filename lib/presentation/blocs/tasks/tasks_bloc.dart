import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../domain/usecases/attach_email_to_task.dart';
import '../../../domain/usecases/create_task.dart';
import '../../../domain/usecases/download_task_attachment.dart';
import '../../../domain/usecases/get_task_attachments.dart';
import '../../../domain/usecases/get_task_lists.dart';
import '../../../domain/usecases/get_tasks.dart';
import '../../../domain/usecases/update_task_due_date.dart';
import '../../../domain/usecases/update_task_status.dart';
import 'tasks_event.dart';
import 'tasks_state.dart';

class TasksBloc extends Bloc<TasksBlocEvent, TasksState> {
  TasksBloc({
    required this._getTaskLists,
    required this._getTasks,
    required this._createTask,
    required this._updateTaskStatus,
    required this._updateTaskDueDate,
    required this._attachEmailToTask,
    required this._getTaskAttachments,
    required this._downloadTaskAttachment,
  }) : super(const TasksInitial()) {
    on<TasksLoadRequested>(_onLoadRequested);
    on<TasksListSelected>(_onListSelected);
    on<TaskStatusToggled>(_onStatusToggled);
    on<TaskCreationRequested>(_onTaskCreated);
    on<TaskDueDateUpdateRequested>(_onDueDateUpdated);
    on<TaskEmailAttachmentTapped>(_onEmailAttachmentTapped);
    on<TaskAttachmentHandled>(_onAttachmentHandled);
  }

  final GetTaskLists _getTaskLists;
  final GetTasks _getTasks;
  final CreateTask _createTask;
  final UpdateTaskStatus _updateTaskStatus;
  final UpdateTaskDueDate _updateTaskDueDate;
  final AttachEmailToTask _attachEmailToTask;
  final GetTaskAttachments _getTaskAttachments;
  final DownloadTaskAttachment _downloadTaskAttachment;

  Future<void> _onLoadRequested(
    TasksLoadRequested event,
    Emitter<TasksState> emit,
  ) async {
    emit(const TasksLoading());

    final listsResult = await _getTaskLists(const NoParams());
    await listsResult.fold(
      (failure) async => emit(TasksError(
        message: failure.message,
        requiresReauth: failure is AuthFailure,
      )),
      (lists) async {
        if (lists.isEmpty) {
          emit(const TasksLoaded(lists: [], tasks: [], selectedListId: ''));
          return;
        }
        final defaultList = lists.firstWhere(
          (l) => l.isDefault,
          orElse: () => lists.first,
        );
        final tasksResult =
            await _getTasks(GetTasksParams(listId: defaultList.id));
        tasksResult.fold(
          (failure) => emit(TasksError(
            message: failure.message,
            requiresReauth: failure is AuthFailure,
          )),
          (tasks) => emit(TasksLoaded(
            lists: lists,
            tasks: tasks,
            selectedListId: defaultList.id,
          )),
        );
      },
    );
  }

  Future<void> _onListSelected(
    TasksListSelected event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;

    emit(current.copyWith(selectedListId: event.listId, tasks: const []));

    final result = await _getTasks(GetTasksParams(listId: event.listId));
    result.fold(
      (failure) => emit(TasksError(
        message: failure.message,
        requiresReauth: failure is AuthFailure,
      )),
      (tasks) => emit(current.copyWith(
        selectedListId: event.listId,
        tasks: tasks,
      )),
    );
  }

  Future<void> _onStatusToggled(
    TaskStatusToggled event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;

    final newStatus = event.currentStatus == TodoTaskStatus.completed
        ? TodoTaskStatus.notStarted
        : TodoTaskStatus.completed;

    if (newStatus == TodoTaskStatus.completed) {
      emit(current.copyWith(
        tasks: current.tasks.where((t) => t.id != event.taskId).toList(),
      ));
    }

    final result = await _updateTaskStatus(UpdateTaskStatusParams(
      listId: event.listId,
      taskId: event.taskId,
      status: newStatus,
    ));

    result.fold(
      (failure) async {
        final reloaded = await _getTasks(
          GetTasksParams(listId: current.selectedListId),
        );
        reloaded.fold((_) {}, (tasks) => emit(current.copyWith(tasks: tasks)));
      },
      (_) {},
    );
  }

  Future<void> _onTaskCreated(
    TaskCreationRequested event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;

    final result = await _createTask(CreateTaskParams(
      listId: event.listId,
      title: event.title,
      dueDate: event.dueDate,
    ));

    await result.fold(
      (_) async {},
      (task) async {
        emit(current.copyWith(tasks: [task, ...current.tasks]));

        if (event.emailId != null) {
          final subject =
              (event.emailSubject?.isNotEmpty == true) ? event.emailSubject! : event.title;
          final safe = subject
              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
              .substring(0, subject.length.clamp(0, 80));

          final attachResult = await _attachEmailToTask(AttachEmailToTaskParams(
            emailId: event.emailId!,
            listId: event.listId,
            taskId: task.id,
            fileName: '$safe.eml',
          ));

          if (attachResult.isRight()) {
            final patched = _PatchedTask(task);
            final current2 = state;
            if (current2 is TasksLoaded) {
              emit(current2.copyWith(
                tasks: [
                  for (final t in current2.tasks)
                    if (t.id == task.id) patched else t,
                ],
              ));
            }
          }
        }
      },
    );
  }

  Future<void> _onDueDateUpdated(
    TaskDueDateUpdateRequested event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;

    // Optimistically update the local task list.
    final optimistic = current.tasks.map((t) {
      if (t.id != event.taskId) return t;
      return _TaskWithDueDate(t, event.dueDate);
    }).toList();
    emit(current.copyWith(tasks: optimistic));

    final result = await _updateTaskDueDate(UpdateTaskDueDateParams(
      listId: event.listId,
      taskId: event.taskId,
      dueDate: event.dueDate,
    ));

    result.fold(
      (_) async {
        // Revert on failure.
        final reloaded = await _getTasks(
          GetTasksParams(listId: current.selectedListId),
        );
        reloaded.fold((_) {}, (tasks) {
          final s = state;
          if (s is TasksLoaded) emit(s.copyWith(tasks: tasks));
        });
      },
      (updated) {
        final s = state;
        if (s is TasksLoaded) {
          emit(s.copyWith(
            tasks: [for (final t in s.tasks) if (t.id == updated.id) updated else t],
          ));
        }
      },
    );
  }

  Future<void> _onEmailAttachmentTapped(
    TaskEmailAttachmentTapped event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;

    final attachmentsResult = await _getTaskAttachments(
      GetTaskAttachmentsParams(listId: event.listId, taskId: event.taskId),
    );

    await attachmentsResult.fold(
      (_) async {},
      (attachments) async {
        final emailAttachment = attachments.firstWhere(
          (a) => a.isEmail,
          orElse: () => attachments.first,
        );

        final bytesResult = await _downloadTaskAttachment(
          DownloadTaskAttachmentParams(
            listId: event.listId,
            taskId: event.taskId,
            attachmentId: emailAttachment.id,
          ),
        );

        bytesResult.fold(
          (_) {},
          (bytes) {
            final current2 = state;
            if (current2 is TasksLoaded) {
              emit(current2.copyWith(pendingEmailAttachmentBytes: bytes));
            }
          },
        );
      },
    );
  }

  Future<void> _onAttachmentHandled(
    TaskAttachmentHandled event,
    Emitter<TasksState> emit,
  ) async {
    final current = state;
    if (current is! TasksLoaded) return;
    emit(current.copyWith(clearPendingAttachment: true));
  }
}

class _PatchedTask extends TodoTask {
  _PatchedTask(TodoTask source)
      : super(
          id: source.id,
          listId: source.listId,
          title: source.title,
          status: source.status,
          importance: source.importance,
          body: source.body,
          dueDateTime: source.dueDateTime,
          completedDateTime: source.completedDateTime,
          isReminderOn: source.isReminderOn,
          reminderDateTime: source.reminderDateTime,
          createdDateTime: source.createdDateTime,
          lastModifiedDateTime: source.lastModifiedDateTime,
          hasAttachments: true,
        );
}

class _TaskWithDueDate extends TodoTask {
  _TaskWithDueDate(TodoTask source, DateTime? due)
      : super(
          id: source.id,
          listId: source.listId,
          title: source.title,
          status: source.status,
          importance: source.importance,
          body: source.body,
          dueDateTime: due,
          completedDateTime: source.completedDateTime,
          isReminderOn: source.isReminderOn,
          reminderDateTime: source.reminderDateTime,
          createdDateTime: source.createdDateTime,
          lastModifiedDateTime: source.lastModifiedDateTime,
          hasAttachments: source.hasAttachments,
        );
}
