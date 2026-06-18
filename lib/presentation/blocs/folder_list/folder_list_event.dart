import 'package:equatable/equatable.dart';

sealed class FolderListEvent extends Equatable {
  const FolderListEvent();

  @override
  List<Object?> get props => [];
}

final class FolderListLoadRequested extends FolderListEvent {
  const FolderListLoadRequested();
}

final class FolderListFolderEmptied extends FolderListEvent {
  const FolderListFolderEmptied({required this.folderId});
  final String folderId;

  @override
  List<Object?> get props => [folderId];
}

final class FolderListCreateFolderRequested extends FolderListEvent {
  const FolderListCreateFolderRequested({
    required this.parentFolderId,
    required this.displayName,
  });

  final String parentFolderId;
  final String displayName;

  @override
  List<Object?> get props => [parentFolderId, displayName];
}

final class FolderListUnreadCountChanged extends FolderListEvent {
  const FolderListUnreadCountChanged({
    required this.folderId,
    required this.unreadCountDelta,
    this.totalCountDelta = 0,
  });
  final String folderId;
  final int unreadCountDelta;
  final int totalCountDelta;

  @override
  List<Object?> get props => [folderId, unreadCountDelta, totalCountDelta];
}
