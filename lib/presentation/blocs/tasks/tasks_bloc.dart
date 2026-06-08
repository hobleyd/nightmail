import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/usecases/usecase.dart';
import '../../../domain/entities/todo_task.dart';
import '../../../domain/usecases/create_task.dart';
import '../../../domain/usecases/get_task_lists.dart';
import '../../../domain/usecases/get_tasks.dart';
import '../../../domain/usecases/update_task_status.dart';
import 'tasks_event.dart';
import 'tasks_state.dart';

class TasksBloc extends Bloc<TasksBlocEvent, TasksState> {
  TasksBloc({
    required this._getTaskLists,
    required this._getTasks,
    required this._createTask,
    required this._updateTaskStatus,
  }) : super(const TasksInitial()) {
    on<TasksLoadRequested>(_onLoadRequested);
    on<TasksListSelected>(_onListSelected);
    on<TaskStatusToggled>(_onStatusToggled);
    on<TaskCreationRequested>(_onTaskCreated);
  }

  final GetTaskLists _getTaskLists;
  final GetTasks _getTasks;
  final CreateTask _createTask;
  final UpdateTaskStatus _updateTaskStatus;

  Future<void> _onLoadRequested(
    TasksLoadRequested event,
    Emitter<TasksState> emit,
  ) async {
    emit(const TasksLoading());

    final listsResult = await _getTaskLists(const NoParams());
    await listsResult.fold(
      (failure) async => emit(TasksError(message: failure.message)),
      (lists) async {
        if (lists.isEmpty) {
          emit(const TasksLoaded(
            lists: [],
            tasks: [],
            selectedListId: '',
          ));
          return;
        }
        final defaultList = lists.firstWhere(
          (l) => l.isDefault,
          orElse: () => lists.first,
        );
        final tasksResult = await _getTasks(
          GetTasksParams(listId: defaultList.id),
        );
        tasksResult.fold(
          (failure) => emit(TasksError(message: failure.message)),
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
      (failure) => emit(TasksError(message: failure.message)),
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

    // Optimistically remove completed tasks from the list.
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
        // Revert by reloading the list.
        final reloaded = await _getTasks(
          GetTasksParams(listId: current.selectedListId),
        );
        reloaded.fold(
          (_) {},
          (tasks) => emit(current.copyWith(tasks: tasks)),
        );
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

    result.fold(
      (_) {},
      (task) => emit(current.copyWith(tasks: [task, ...current.tasks])),
    );
  }
}
