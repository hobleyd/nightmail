import 'package:equatable/equatable.dart';

import '../../../domain/entities/todo_task.dart';

sealed class TasksBlocEvent extends Equatable {
  const TasksBlocEvent();

  @override
  List<Object?> get props => [];
}

final class TasksLoadRequested extends TasksBlocEvent {
  const TasksLoadRequested();
}

final class TasksListSelected extends TasksBlocEvent {
  const TasksListSelected({required this.listId});
  final String listId;

  @override
  List<Object?> get props => [listId];
}

final class TaskStatusToggled extends TasksBlocEvent {
  const TaskStatusToggled({
    required this.listId,
    required this.taskId,
    required this.currentStatus,
  });

  final String listId;
  final String taskId;
  final TodoTaskStatus currentStatus;

  @override
  List<Object?> get props => [listId, taskId, currentStatus];
}

final class TaskCreationRequested extends TasksBlocEvent {
  const TaskCreationRequested({
    required this.listId,
    required this.title,
    this.dueDate,
  });

  final String listId;
  final String title;
  final DateTime? dueDate;

  @override
  List<Object?> get props => [listId, title, dueDate];
}
