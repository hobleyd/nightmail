import 'package:equatable/equatable.dart';

class TodoTaskList extends Equatable {
  const TodoTaskList({
    required this.id,
    required this.displayName,
    this.isDefault = false,
  });

  final String id;
  final String displayName;
  final bool isDefault;

  @override
  List<Object?> get props => [id, displayName, isDefault];
}
