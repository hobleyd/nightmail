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

/// Re-reads the current folder from the local cache only — no network call.
/// Dispatched when something else (background poll, delta sync) has already
/// written fresh data into the cache, so the list can repaint instantly.
final class EmailListCacheRefreshRequested extends EmailListEvent {
  const EmailListCacheRefreshRequested();
}

final class EmailListMarkReadRequested extends EmailListEvent {
  const EmailListMarkReadRequested({required this.emailId, required this.isRead});
  final String emailId;
  final bool isRead;

  @override
  List<Object?> get props => [emailId, isRead];
}

/// Marks every listed email read/unread in one shot. Used when opening a
/// conversation thread so *all* its unread messages flip, not just the one
/// shown in the reading pane.
final class EmailListMarkThreadReadRequested extends EmailListEvent {
  const EmailListMarkThreadReadRequested({
    required this.emailIds,
    required this.isRead,
  });
  final List<String> emailIds;
  final bool isRead;

  @override
  List<Object?> get props => [emailIds, isRead];
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

/// Deletes an entire conversation thread. Only messages physically in the
/// folder currently being viewed are deleted — messages the thread has
/// already been filed into other folders (surfaced here by cross-folder
/// thread augmentation on Graph/Gmail) are left untouched. The whole thread
/// is removed from the current view regardless, since it only appears here on
/// the strength of its in-folder members.
final class EmailListConversationDeleted extends EmailListEvent {
  const EmailListConversationDeleted({required this.conversationId});
  final String conversationId;

  @override
  List<Object?> get props => [conversationId];
}

final class EmailListEmailsMoved extends EmailListEvent {
  const EmailListEmailsMoved({
    required this.emailIds,
    required this.destinationFolderId,
    this.conversationId,
  });
  final List<String> emailIds;
  final String destinationFolderId;
  final String? conversationId;

  @override
  List<Object?> get props => [emailIds, destinationFolderId, conversationId];
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

final class EmailListSearchModeActivated extends EmailListEvent {
  const EmailListSearchModeActivated();
}

final class EmailListSearchRequested extends EmailListEvent {
  const EmailListSearchRequested({required this.query});
  final String query;

  @override
  List<Object?> get props => [query];
}

final class EmailListSearchCleared extends EmailListEvent {
  const EmailListSearchCleared();
}
