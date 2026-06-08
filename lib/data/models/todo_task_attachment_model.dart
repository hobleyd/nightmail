import '../../domain/entities/todo_task_attachment.dart';

class TodoTaskAttachmentModel extends TodoTaskAttachment {
  const TodoTaskAttachmentModel({
    required super.id,
    required super.name,
    required super.contentType,
    required super.size,
  });

  factory TodoTaskAttachmentModel.fromJson(Map<String, dynamic> json) {
    return TodoTaskAttachmentModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'attachment',
      contentType: json['contentType'] as String? ?? 'application/octet-stream',
      size: json['size'] as int? ?? 0,
    );
  }
}
