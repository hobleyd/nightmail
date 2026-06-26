import 'package:equatable/equatable.dart';

/// The role of a message in an AI conversation.
enum AiRole { system, user, assistant }

/// A single message in an AI inference request.
class AiMessage extends Equatable {
  const AiMessage({required this.role, required this.content});

  final AiRole role;
  final String content;

  @override
  List<Object?> get props => [role, content];
}
