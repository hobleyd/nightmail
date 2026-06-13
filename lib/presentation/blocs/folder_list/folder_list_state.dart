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

final class FolderListLoaded extends FolderListState {
  const FolderListLoaded({required this.folders, this.isRefreshing = false});
  final List<EmailFolder> folders;
  final bool isRefreshing;

  FolderListLoaded copyWith({List<EmailFolder>? folders, bool? isRefreshing}) =>
      FolderListLoaded(
        folders: folders ?? this.folders,
        isRefreshing: isRefreshing ?? this.isRefreshing,
      );

  @override
  List<Object?> get props => [folders, isRefreshing];
}

final class FolderListError extends FolderListState {
  const FolderListError({required this.message, this.isAuthFailure = false});
  final String message;
  final bool isAuthFailure;

  @override
  List<Object?> get props => [message, isAuthFailure];
}
