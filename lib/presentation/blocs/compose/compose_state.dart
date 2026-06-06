import 'package:equatable/equatable.dart';

sealed class ComposeState extends Equatable {
  const ComposeState();

  @override
  List<Object?> get props => [];
}

final class ComposeInitial extends ComposeState {
  const ComposeInitial();
}

final class ComposeSending extends ComposeState {
  const ComposeSending();
}

final class ComposeSent extends ComposeState {
  const ComposeSent();
}

final class ComposeError extends ComposeState {
  const ComposeError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
