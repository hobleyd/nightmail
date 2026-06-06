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

  @override
  List<Object?> get props => [folders];
}

final class FolderListError extends FolderListState {
  const FolderListError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
