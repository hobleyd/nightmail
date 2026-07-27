import 'dart:typed_data';

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
  TasksLoaded({
    required this.lists,
    required List<TodoTask> tasks,
    required this.selectedListId,
    this.pendingEmailAttachmentBytes,
  }) : tasks = _sortedByDueDate(tasks);

  final List<TodoTaskList> lists;

  /// Always ordered by due date, earliest first. Sorting here rather than in
  /// the pane keeps every emit path (load, create, optimistic due-date change)
  /// consistent without each one having to remember to re-sort.
  final List<TodoTask> tasks;
  final String selectedListId;
  final Uint8List? pendingEmailAttachmentBytes;

  /// Earliest due date first; undated tasks sink to the bottom. Ties (and the
  /// undated group) keep their incoming order — `List.sort` is not stable, so
  /// the original index is the final tiebreaker.
  static List<TodoTask> _sortedByDueDate(List<TodoTask> tasks) {
    final indexed = [
      for (var i = 0; i < tasks.length; i++) (index: i, task: tasks[i]),
    ];
    indexed.sort((a, b) {
      final aDue = a.task.dueDateTime;
      final bDue = b.task.dueDateTime;
      if (aDue != null && bDue != null) {
        final byDue = aDue.compareTo(bDue);
        if (byDue != 0) return byDue;
      } else if (aDue != null) {
        return -1;
      } else if (bDue != null) {
        return 1;
      }
      return a.index.compareTo(b.index);
    });
    return [for (final e in indexed) e.task];
  }

  @override
  List<Object?> get props => [lists, tasks, selectedListId, pendingEmailAttachmentBytes];

  TasksLoaded copyWith({
    List<TodoTaskList>? lists,
    List<TodoTask>? tasks,
    String? selectedListId,
    Uint8List? pendingEmailAttachmentBytes,
    bool clearPendingAttachment = false,
  }) {
    return TasksLoaded(
      lists: lists ?? this.lists,
      tasks: tasks ?? this.tasks,
      selectedListId: selectedListId ?? this.selectedListId,
      pendingEmailAttachmentBytes: clearPendingAttachment
          ? null
          : (pendingEmailAttachmentBytes ?? this.pendingEmailAttachmentBytes),
    );
  }
}

final class TasksError extends TasksState {
  const TasksError({required this.message, this.requiresReauth = false});
  final String message;
  final bool requiresReauth;

  @override
  List<Object?> get props => [message, requiresReauth];
}
