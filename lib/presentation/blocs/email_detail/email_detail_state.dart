import 'package:equatable/equatable.dart';

import '../../../domain/entities/email.dart';

sealed class EmailDetailState extends Equatable {
  const EmailDetailState();

  @override
  List<Object?> get props => [];
}

final class EmailDetailInitial extends EmailDetailState {
  const EmailDetailInitial();
}

final class EmailDetailLoading extends EmailDetailState {
  const EmailDetailLoading();
}

final class EmailDetailLoaded extends EmailDetailState {
  const EmailDetailLoaded({required this.email});
  final Email email;

  @override
  List<Object?> get props => [email];
}

final class EmailDetailError extends EmailDetailState {
  const EmailDetailError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
