import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/usecases/usecase.dart';
import '../../../core/utils/stale_data_retry.dart';
import '../../../domain/entities/email_folder.dart';
import '../../../domain/usecases/create_folder.dart';
import '../../../domain/usecases/get_cached_folders.dart';
import '../../../domain/usecases/get_mail_folders.dart';
import '../../../domain/usecases/move_folder.dart';
import '../../../domain/usecases/rename_folder.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'folder_list_event.dart';
import 'folder_list_state.dart';

class FolderListBloc extends Bloc<FolderListEvent, FolderListState> {
  FolderListBloc({
    required this._getMailFolders,
    required this._getCachedFolders,
    required this._createFolder,
    required this._renameFolder,
    required this._moveFolder,
    required this._accountManager,
    List<Duration> staleRetryDelays = staleDataRetryDelays,
  })  : _staleRetryDelays = staleRetryDelays,
        super(const FolderListInitial()) {
    on<FolderListLoadRequested>(_onLoadRequested);
    on<FolderListFolderEmptied>(_onFolderEmptied);
    on<FolderListUnreadCountChanged>(_onUnreadCountChanged);
    on<FolderListCreateFolderRequested>(_onCreateFolderRequested);
    on<FolderListRenameFolderRequested>(_onRenameFolderRequested);
    on<FolderListMoveFolderRequested>(_onMoveFolderRequested);
  }


  final GetMailFolders _getMailFolders;
  final GetCachedFolders _getCachedFolders;
  final CreateFolder _createFolder;
  final RenameFolder _renameFolder;
  final MoveFolder _moveFolder;
  final AccountManager _accountManager;
  final List<Duration> _staleRetryDelays;

  /// Bumped by every [FolderListLoadRequested]. This event is added from
  /// several places that routinely overlap at startup — `HomePage.build`, the
  /// poller's `pollGeneration` listener, the refresh button — and events use
  /// the default concurrent transformer, so without this an older run's fetch
  /// can resolve last and walk the counts backwards.
  int _loadGeneration = 0;

  Future<void> _onLoadRequested(
    FolderListLoadRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final accountId = _accountManager.activeAccount?.id;
    final myGeneration = ++_loadGeneration;
    bool hasFolders = false;

    // Phase 1: show something at once rather than a spinner. Folders already
    // in state are preferred over the cache — re-reading the cache over a
    // fresher result would flick the counts back to what was on disk, and
    // would also discard the optimistic deltas applied by
    // [FolderListUnreadCountChanged].
    final current = state;
    if (current is FolderListLoaded && current.folders.isNotEmpty) {
      hasFolders = true;
      emit(current.copyWith(isRefreshing: true));
    } else if (accountId != null) {
      final cacheResult = await _getCachedFolders(accountId);
      if (isClosed || myGeneration != _loadGeneration) return;
      cacheResult.fold(
        (_) => emit(const FolderListLoading()),
        (cached) {
          if (cached.isEmpty) {
            emit(const FolderListLoading());
          } else {
            hasFolders = true;
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

    // Phase 2: network fetch — always attempted regardless of cache state.
    //
    // A failure here while cached folders are on screen is swallowed: their
    // counts stay visible, because a stale count is more use than none. But
    // that leaves them reading as authoritative, so the fetch is retried a
    // few times rather than abandoned — the cold-start failures are transient
    // (an OAuth refresh racing the machine's network coming up, the
    // connectivity probe fast-failing before the route settled) and nothing
    // else re-requests the list until the user refreshes by hand.
    for (var attempt = 0;; attempt++) {
      final result = await _getMailFolders(const NoParams());
      if (isClosed || myGeneration != _loadGeneration) return;

      var succeeded = false;
      result.fold(
        (failure) {
          debugPrint('[FolderList] fetch failed on attempt ${attempt + 1} '
              '(${hasFolders ? 'stale folders on screen' : 'nothing to show'}): '
              '${failure.runtimeType} — ${failure.message}');
          if (hasFolders) {
            final s = state;
            if (s is FolderListLoaded) emit(s.copyWith(isRefreshing: false));
          } else {
            emit(FolderListError(
              message: failure.message,
              isAuthFailure: failure is AuthFailure,
            ));
          }
        },
        (folders) {
          succeeded = true;
          if (attempt > 0) {
            debugPrint(
                '[FolderList] fetch recovered on attempt ${attempt + 1}');
          }
          emit(FolderListLoaded(folders: _sorted(folders)));
        },
      );

      // Only a stale list is worth retrying behind the user's back: with no
      // folders to show, the error above is on screen and offers a retry.
      if (succeeded || !hasFolders || attempt >= _staleRetryDelays.length) {
        if (!succeeded && hasFolders) {
          debugPrint('[FolderList] giving up after ${attempt + 1} attempts — '
              'the counts on screen are the cached ones');
        }
        return;
      }
      await Future<void>.delayed(_staleRetryDelays[attempt]);
      if (isClosed || myGeneration != _loadGeneration) return;
    }
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

  Future<void> _onCreateFolderRequested(
    FolderListCreateFolderRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final result = await _createFolder(CreateFolderParams(
      parentFolderId: event.parentFolderId,
      displayName: event.displayName,
    ));
    result.fold(
      (_) {},
      (_) => add(const FolderListLoadRequested()),
    );
  }

  Future<void> _onRenameFolderRequested(
    FolderListRenameFolderRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final result = await _renameFolder(RenameFolderParams(
      folderId: event.folderId,
      newDisplayName: event.newDisplayName,
    ));
    result.fold(
      (_) {},
      (_) => add(const FolderListLoadRequested()),
    );
  }

  Future<void> _onMoveFolderRequested(
    FolderListMoveFolderRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final result = await _moveFolder(MoveFolderParams(
      folderId: event.folderId,
      newParentFolderId: event.newParentFolderId,
    ));
    result.fold(
      (_) {},
      (_) => add(const FolderListLoadRequested()),
    );
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
