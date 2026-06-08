import '../../domain/entities/todo_task_list.dart';

class TodoTaskListModel extends TodoTaskList {
  const TodoTaskListModel({
    required super.id,
    required super.displayName,
    super.isDefault,
  });

  factory TodoTaskListModel.fromJson(Map<String, dynamic> json) {
    return TodoTaskListModel(
      id: json['id'] as String,
      displayName: json['displayName'] as String? ?? 'Tasks',
      isDefault: json['wellknownListName'] == 'defaultList',
    );
  }
}
