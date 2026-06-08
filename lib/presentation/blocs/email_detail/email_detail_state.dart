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
  const EmailDetailLoaded({required this.email, this.senderAnomalyScore});
  final Email email;
  final double? senderAnomalyScore; // null = no anomaly; 0.75–1.0 = anomaly

  @override
  List<Object?> get props => [email, senderAnomalyScore];
}

final class EmailDetailError extends EmailDetailState {
  const EmailDetailError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
