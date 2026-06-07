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
