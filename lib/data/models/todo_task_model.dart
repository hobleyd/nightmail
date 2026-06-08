import '../../domain/entities/todo_task.dart';

class TodoTaskModel extends TodoTask {
  const TodoTaskModel({
    required super.id,
    required super.listId,
    required super.title,
    super.status,
    super.importance,
    super.body,
    super.dueDateTime,
    super.completedDateTime,
    super.isReminderOn,
    super.reminderDateTime,
    super.createdDateTime,
    super.lastModifiedDateTime,
  });

  factory TodoTaskModel.fromJson(
      Map<String, dynamic> json, {
      required String listId,
  }) {
    return TodoTaskModel(
      id: json['id'] as String,
      listId: listId,
      title: json['title'] as String? ?? '(No title)',
      status: _parseStatus(json['status'] as String?),
      importance: _parseImportance(json['importance'] as String?),
      body: _parseBody(json['body'] as Map<String, dynamic>?),
      dueDateTime: _parseDate(json['dueDateTime'] as Map<String, dynamic>?),
      completedDateTime:
          _parseDate(json['completedDateTime'] as Map<String, dynamic>?),
      isReminderOn: json['isReminderOn'] as bool? ?? false,
      reminderDateTime:
          _parseDate(json['reminderDateTime'] as Map<String, dynamic>?),
      createdDateTime: _parseIso(json['createdDateTime'] as String?),
      lastModifiedDateTime: _parseIso(json['lastModifiedDateTime'] as String?),
    );
  }

  static TodoTaskStatus _parseStatus(String? value) {
    return switch (value?.toLowerCase()) {
      'completed' => TodoTaskStatus.completed,
      'inprogress' => TodoTaskStatus.inProgress,
      'waitingonothers' => TodoTaskStatus.waitingOnOthers,
      'deferred' => TodoTaskStatus.deferred,
      _ => TodoTaskStatus.notStarted,
    };
  }

  static TodoTaskImportance _parseImportance(String? value) {
    return switch (value?.toLowerCase()) {
      'high' => TodoTaskImportance.high,
      'low' => TodoTaskImportance.low,
      _ => TodoTaskImportance.normal,
    };
  }

  static String? _parseBody(Map<String, dynamic>? map) {
    if (map == null) return null;
    final content = map['content'] as String?;
    return (content == null || content.isEmpty) ? null : content;
  }

  static DateTime? _parseDate(Map<String, dynamic>? map) {
    if (map == null) return null;
    final dt = map['dateTime'] as String?;
    if (dt == null) return null;
    return DateTime.tryParse(dt)?.toLocal();
  }

  static DateTime? _parseIso(String? value) {
    if (value == null) return null;
    return DateTime.tryParse(value)?.toLocal();
  }
}
