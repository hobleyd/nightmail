import 'package:equatable/equatable.dart';

sealed class EmailDetailEvent extends Equatable {
  const EmailDetailEvent();

  @override
  List<Object?> get props => [];
}

final class EmailDetailLoadRequested extends EmailDetailEvent {
  const EmailDetailLoadRequested({required this.emailId});
  final String emailId;

  @override
  List<Object?> get props => [emailId];
}

final class EmailDetailCleared extends EmailDetailEvent {
  const EmailDetailCleared();
}
