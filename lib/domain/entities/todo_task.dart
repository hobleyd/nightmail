import 'package:equatable/equatable.dart';

enum TodoTaskStatus { notStarted, inProgress, completed, waitingOnOthers, deferred }

enum TodoTaskImportance { low, normal, high }

class TodoTask extends Equatable {
  const TodoTask({
    required this.id,
    required this.listId,
    required this.title,
    this.status = TodoTaskStatus.notStarted,
    this.importance = TodoTaskImportance.normal,
    this.body,
    this.dueDateTime,
    this.completedDateTime,
    this.isReminderOn = false,
    this.reminderDateTime,
    this.createdDateTime,
    this.lastModifiedDateTime,
    this.hasAttachments = false,
  });

  final String id;
  final String listId;
  final String title;
  final TodoTaskStatus status;
  final TodoTaskImportance importance;
  final String? body;
  final DateTime? dueDateTime;
  final DateTime? completedDateTime;
  final bool isReminderOn;
  final DateTime? reminderDateTime;
  final DateTime? createdDateTime;
  final DateTime? lastModifiedDateTime;
  final bool hasAttachments;

  bool get isCompleted => status == TodoTaskStatus.completed;

  @override
  List<Object?> get props => [id, hasAttachments, status, dueDateTime, body];
}
