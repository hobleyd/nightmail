import 'package:equatable/equatable.dart';

import '../../../domain/entities/email_folder.dart';

sealed class FolderListState extends Equatable {
  const FolderListState();

  @override
  List<Object?> get props => [];
}

final class FolderListInitial extends FolderListState {
  const FolderListInitial();
}

final class FolderListLoading extends FolderListState {
  const FolderListLoading();
}

/// A folder the user has asked for but the server has not confirmed yet.
///
/// It deliberately carries no id: until the create returns, there is no id
/// that means anything to the server, and a stand-in one would be a valid
/// move destination as far as the rest of the app could tell. So this is
/// drawn as a row and is nothing else — not selectable, not a drop target.
final class PendingFolderCreation extends Equatable {
  const PendingFolderCreation({
    required this.parentFolderId,
    required this.displayName,
    this.error,
  });

  final String parentFolderId;
  final String displayName;

  /// Null while the create is in flight; the failure message once it has
  /// failed. The row stays on screen either way — a create that silently
  /// vanished is how "I made a folder and nothing happened" used to read.
  final String? error;

  bool get hasFailed => error != null;

  PendingFolderCreation withError(String message) => PendingFolderCreation(
        parentFolderId: parentFolderId,
        displayName: displayName,
        error: message,
      );

  @override
  List<Object?> get props => [parentFolderId, displayName, error];
}

final class FolderListLoaded extends FolderListState {
  const FolderListLoaded({
    required this.folders,
    this.isRefreshing = false,
    this.pendingCreate,
  });
  final List<EmailFolder> folders;
  final bool isRefreshing;
  final PendingFolderCreation? pendingCreate;

  FolderListLoaded copyWith({
    List<EmailFolder>? folders,
    bool? isRefreshing,
    PendingFolderCreation? pendingCreate,
    bool clearPendingCreate = false,
  }) =>
      FolderListLoaded(
        folders: folders ?? this.folders,
        isRefreshing: isRefreshing ?? this.isRefreshing,
        pendingCreate:
            clearPendingCreate ? null : (pendingCreate ?? this.pendingCreate),
      );

  @override
  List<Object?> get props => [folders, isRefreshing, pendingCreate];
}

final class FolderListError extends FolderListState {
  const FolderListError({required this.message, this.isAuthFailure = false});
  final String message;
  final bool isAuthFailure;

  @override
  List<Object?> get props => [message, isAuthFailure];
}
