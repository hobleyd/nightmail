import 'package:equatable/equatable.dart';

import '../../../domain/entities/todo_task.dart';
import '../../../domain/entities/todo_task_list.dart';

sealed class TasksState extends Equatable {
  const TasksState();

  @override
  List<Object?> get props => [];
}

final class TasksInitial extends TasksState {
  const TasksInitial();
}

final class TasksLoading extends TasksState {
  const TasksLoading();
}

final class TasksLoaded extends TasksState {
  const TasksLoaded({
    required this.lists,
    required this.tasks,
    required this.selectedListId,
  });

  final List<TodoTaskList> lists;
  final List<TodoTask> tasks;
  final String selectedListId;

  @override
  List<Object?> get props => [lists, tasks, selectedListId];

  TasksLoaded copyWith({
    List<TodoTaskList>? lists,
    List<TodoTask>? tasks,
    String? selectedListId,
  }) {
    return TasksLoaded(
      lists: lists ?? this.lists,
      tasks: tasks ?? this.tasks,
      selectedListId: selectedListId ?? this.selectedListId,
    );
  }
}

final class TasksError extends TasksState {
  const TasksError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
