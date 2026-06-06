import 'package:equatable/equatable.dart';

sealed class EmailListEvent extends Equatable {
  const EmailListEvent();

  @override
  List<Object?> get props => [];
}

final class EmailListLoadRequested extends EmailListEvent {
  const EmailListLoadRequested({this.folderId});
  final String? folderId;

  @override
  List<Object?> get props => [folderId];
}

final class EmailListLoadMoreRequested extends EmailListEvent {
  const EmailListLoadMoreRequested();
}

final class EmailListRefreshRequested extends EmailListEvent {
  const EmailListRefreshRequested({this.folderId});
  final String? folderId;

  @override
  List<Object?> get props => [folderId];
}

final class EmailListMarkReadRequested extends EmailListEvent {
  const EmailListMarkReadRequested({required this.emailId, required this.isRead});
  final String emailId;
  final bool isRead;

  @override
  List<Object?> get props => [emailId, isRead];
}

final class EmailListToggleConversation extends EmailListEvent {
  const EmailListToggleConversation({required this.conversationId});
  final String conversationId;

  @override
  List<Object?> get props => [conversationId];
}

final class EmailListEmailDeleted extends EmailListEvent {
  const EmailListEmailDeleted({required this.emailId});
  final String emailId;

  @override
  List<Object?> get props => [emailId];
}
