import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../../domain/entities/email_folder.dart';
import '../../../domain/usecases/get_cached_folders.dart';
import '../../../domain/usecases/get_mail_folders.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'folder_list_event.dart';
import 'folder_list_state.dart';

class FolderListBloc extends Bloc<FolderListEvent, FolderListState> {
  FolderListBloc({
    required this._getMailFolders,
    required this._getCachedFolders,
    required this._accountManager,
  }) : super(const FolderListInitial()) {
    on<FolderListLoadRequested>(_onLoadRequested);
    on<FolderListFolderEmptied>(_onFolderEmptied);
    on<FolderListUnreadCountChanged>(_onUnreadCountChanged);
  }

  final GetMailFolders _getMailFolders;
  final GetCachedFolders _getCachedFolders;
  final AccountManager _accountManager;

  Future<void> _onLoadRequested(
    FolderListLoadRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final accountId = _accountManager.activeAccount?.id;
    bool hasCachedData = false;

    // Phase 1: serve cache immediately so folders appear without a spinner
    if (accountId != null) {
      final cacheResult = await _getCachedFolders(accountId);
      cacheResult.fold(
        (_) => emit(const FolderListLoading()),
        (cached) {
          if (cached.isEmpty) {
            emit(const FolderListLoading());
          } else {
            hasCachedData = true;
            emit(FolderListLoaded(
              folders: _sorted(cached),
              isRefreshing: true,
            ));
          }
        },
      );
    } else {
      emit(const FolderListLoading());
    }

    // Phase 2: network fetch — always attempted regardless of cache state
    final result = await _getMailFolders(const NoParams());
    result.fold(
      (failure) {
        if (hasCachedData) {
          final s = state;
          if (s is FolderListLoaded) emit(s.copyWith(isRefreshing: false));
        } else {
          emit(FolderListError(
            message: failure.message,
            isAuthFailure: failure is AuthFailure,
          ));
        }
      },
      (folders) => emit(FolderListLoaded(folders: _sorted(folders))),
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

  void _onUnreadCountChanged(
    FolderListUnreadCountChanged event,
    Emitter<FolderListState> emit,
  ) {
    final current = state;
    if (current is! FolderListLoaded) return;
    emit(current.copyWith(
      folders: current.folders.map((f) {
        if (f.id != event.folderId) return f;
        return f.copyWith(
          unreadItemCount: f.unreadItemCount + event.unreadCountDelta,
          totalItemCount: f.totalItemCount + event.totalCountDelta,
        );
      }).toList(),
    ));
  }

  static List<EmailFolder> _sorted(List<EmailFolder> folders) {
    return [...folders]..sort((a, b) {
        final aIdx = _systemFolderOrder(a.displayName);
        final bIdx = _systemFolderOrder(b.displayName);
        if (aIdx != bIdx) return aIdx.compareTo(bIdx);
        return a.displayName.compareTo(b.displayName);
      });
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
