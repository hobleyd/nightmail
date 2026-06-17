import 'package:equatable/equatable.dart';

sealed class EmailListEvent extends Equatable {
  const EmailListEvent();

  @override
  List<Object?> get props => [];
}

final class EmailListLoadRequested extends EmailListEvent {
  const EmailListLoadRequested({this.folderId, this.folderDisplayName});
  final String? folderId;
  final String? folderDisplayName;

  @override
  List<Object?> get props => [folderId, folderDisplayName];
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

final class EmailListEmailsBulkDeleted extends EmailListEvent {
  const EmailListEmailsBulkDeleted({required this.emailIds});
  final List<String> emailIds;

  @override
  List<Object?> get props => [emailIds];
}

final class EmailListEmailsMoved extends EmailListEvent {
  const EmailListEmailsMoved({
    required this.emailIds,
    required this.destinationFolderId,
  });
  final List<String> emailIds;
  final String destinationFolderId;

  @override
  List<Object?> get props => [emailIds, destinationFolderId];
}

final class EmailListFolderEmptied extends EmailListEvent {
  const EmailListFolderEmptied({
    required this.folderId,
    this.permanentDelete = false,
  });
  final String folderId;
  final bool permanentDelete;

  @override
  List<Object?> get props => [folderId, permanentDelete];
}

final class EmailListJunkReported extends EmailListEvent {
  const EmailListJunkReported({required this.emailIds});
  final List<String> emailIds;

  @override
  List<Object?> get props => [emailIds];
}

final class EmailListCleared extends EmailListEvent {
  const EmailListCleared();
}
