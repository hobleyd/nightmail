import 'package:equatable/equatable.dart';

class TodoTaskAttachment extends Equatable {
  const TodoTaskAttachment({
    required this.id,
    required this.name,
    required this.contentType,
    required this.size,
  });

  final String id;
  final String name;
  final String contentType;
  final int size;

  bool get isEmail =>
      contentType == 'message/rfc822' || name.toLowerCase().endsWith('.eml');

  @override
  List<Object?> get props => [id, name, contentType, size];
}
