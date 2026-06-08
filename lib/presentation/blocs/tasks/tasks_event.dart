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
    this.emailId,
    this.emailSubject,
  });

  final String listId;
  final String title;
  final DateTime? dueDate;
  final String? emailId;
  final String? emailSubject;

  @override
  List<Object?> get props => [listId, title, dueDate, emailId];
}

final class TaskEmailAttachmentTapped extends TasksBlocEvent {
  const TaskEmailAttachmentTapped({
    required this.listId,
    required this.taskId,
  });

  final String listId;
  final String taskId;

  @override
  List<Object?> get props => [listId, taskId];
}

final class TaskAttachmentHandled extends TasksBlocEvent {
  const TaskAttachmentHandled();
}

final class TaskDueDateUpdateRequested extends TasksBlocEvent {
  const TaskDueDateUpdateRequested({
    required this.listId,
    required this.taskId,
    required this.dueDate,
  });

  final String listId;
  final String taskId;
  final DateTime? dueDate;

  @override
  List<Object?> get props => [listId, taskId, dueDate];
}
