import 'package:equatable/equatable.dart';

class EmailAttachment extends Equatable {
  const EmailAttachment({
    required this.id,
    required this.name,
    required this.contentType,
    required this.size,
  });

  final String id;
  final String name;
  final String contentType;
  final int size;

  @override
  List<Object?> get props => [id, name, contentType, size];
}
