import 'package:equatable/equatable.dart';

sealed class FolderListEvent extends Equatable {
  const FolderListEvent();

  @override
  List<Object?> get props => [];
}

final class FolderListLoadRequested extends FolderListEvent {
  const FolderListLoadRequested();
}
