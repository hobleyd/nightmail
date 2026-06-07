import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/usecases/usecase.dart';
import '../../../domain/usecases/get_mail_folders.dart';
import 'folder_list_event.dart';
import 'folder_list_state.dart';

class FolderListBloc extends Bloc<FolderListEvent, FolderListState> {
  FolderListBloc({required this._getMailFolders})
      : super(const FolderListInitial()) {
    on<FolderListLoadRequested>(_onLoadRequested);
    on<FolderListFolderEmptied>(_onFolderEmptied);
  }

  final GetMailFolders _getMailFolders;

  Future<void> _onLoadRequested(
    FolderListLoadRequested event,
    Emitter<FolderListState> emit,
  ) async {
    emit(const FolderListLoading());
    final result = await _getMailFolders(const NoParams());
    result.fold(
      (failure) => emit(FolderListError(message: failure.message)),
      (folders) {
        // Sort: well-known system folders first, then alphabetically.
        final sorted = [...folders]..sort((a, b) {
            final aIdx = _systemFolderOrder(a.displayName);
            final bIdx = _systemFolderOrder(b.displayName);
            if (aIdx != bIdx) return aIdx.compareTo(bIdx);
            return a.displayName.compareTo(b.displayName);
          });
        emit(FolderListLoaded(folders: sorted));
      },
    );
  }

  void _onFolderEmptied(
    FolderListFolderEmptied event,
    Emitter<FolderListState> emit,
  ) {
    final current = state;
    if (current is! FolderListLoaded) return;
    emit(current.copyWith(
      folders: current.folders.map((f) {
        if (f.id != event.folderId) return f;
        return f.copyWith(totalItemCount: 0, unreadItemCount: 0);
      }).toList(),
    ));
  }

  static int _systemFolderOrder(String name) {
    return switch (name.toLowerCase()) {
      'inbox' => 0,
      'drafts' => 1,
      'sent items' => 2,
      'deleted items' => 3,
      'junk email' => 4,
      'archive' => 5,
      _ => 99,
    };
  }
}
