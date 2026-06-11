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
  const FolderListLoaded({required this.folders});
  final List<EmailFolder> folders;

  FolderListLoaded copyWith({List<EmailFolder>? folders}) =>
      FolderListLoaded(folders: folders ?? this.folders);

  @override
  List<Object?> get props => [folders];
}

final class FolderListError extends FolderListState {
  const FolderListError({required this.message, this.isAuthFailure = false});
  final String message;
  final bool isAuthFailure;

  @override
  List<Object?> get props => [message, isAuthFailure];
}
