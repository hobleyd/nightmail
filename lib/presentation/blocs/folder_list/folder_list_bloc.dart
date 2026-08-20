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
    on<FolderListCreateFolderDismissed>(_onCreateFolderDismissed);
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

  /// The account the folders in [state] belong to. An account switch does not
  /// clear this bloc — it only re-requests — so without this the phase-1
  /// shortcut below would re-emit the *previous* account's folders. HomePage
  /// auto-selects the Inbox of the first loaded list it sees and then stands
  /// down, so it would fasten onto an Inbox id the new account does not have:
  /// no folder highlighted and a message list loading a dead id.
  String? _loadedAccountId;

  /// Folders this bloc created that no server folder list has come back
  /// naming yet, and how many lists have now omitted each one.
  ///
  /// A create returns a real server id, so the folder is inserted into state
  /// the moment it exists — but a folder-tree fetch is a wholesale replacement,
  /// and both providers can answer one built a moment too early (Graph
  /// propagation, Gmail's cached label list) *without* the new folder. That
  /// would delete the row the user just watched appear. So an unconfirmed
  /// folder is merged back into a list that omits it, for a few lists only:
  /// past that, the omission is more likely to be the truth (the folder was
  /// deleted from another client) than lag.
  final Map<String, ({EmailFolder folder, int misses})> _unconfirmedFolders = {};

  static const int _unconfirmedFolderGrace = 3;

  Future<void> _onLoadRequested(
    FolderListLoadRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final accountId = _accountManager.activeAccount?.id;
    final myGeneration = ++_loadGeneration;
    bool hasFolders = false;

    // An unconfirmed folder belongs to the mailbox it was created in; merging
    // it into another account's list would invent a folder there.
    if (accountId != _loadedAccountId) _unconfirmedFolders.clear();

    // A create in flight (or one showing its failure) survives a reload: this
    // event fires from the poller and the refresh button as well, and neither
    // has anything to say about a folder the user is in the middle of making.
    // It does not survive an account switch — its parent folder is in the
    // mailbox being left, so the row would have nothing to hang under and
    // nothing on screen could clear it again.
    final before = state;
    final pendingCreate =
        before is FolderListLoaded && accountId == _loadedAccountId
            ? before.pendingCreate
            : null;

    // Phase 1: show something at once rather than a spinner. Folders already
    // in state are preferred over the cache — re-reading the cache over a
    // fresher result would flick the counts back to what was on disk, and
    // would also discard the optimistic deltas applied by
    // [FolderListUnreadCountChanged]. That only holds for the account those
    // folders came from: after a switch they are another mailbox's, and the
    // cache is the newer of the two.
    final current = state;
    if (current is FolderListLoaded &&
        current.folders.isNotEmpty &&
        _loadedAccountId == accountId) {
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
            _loadedAccountId = accountId;
            emit(FolderListLoaded(
              folders: _sorted(_withUnconfirmed(cached)),
              isRefreshing: true,
              pendingCreate: pendingCreate,
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
          _loadedAccountId = accountId;
          emit(FolderListLoaded(
            folders: _sorted(_reconcileUnconfirmed(folders)),
            pendingCreate: pendingCreate,
          ));
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

  /// Creating a folder shows it at once and reconciles afterwards.
  ///
  /// Three stages, and the middle one is the point: the typed name stays on
  /// screen as a [PendingFolderCreation] row for as long as the create is in
  /// flight, then becomes a real folder row carrying the **server's** id the
  /// moment the create returns — without waiting for the folder-tree fetch
  /// that follows, which walks every level of the hierarchy and is what used
  /// to make a new folder disappear for a second or more.
  ///
  /// The reconcile is still requested, because only the server can say what
  /// the folder's counts are and where it sorts among its siblings; it just
  /// no longer stands between the user and seeing their folder.
  Future<void> _onCreateFolderRequested(
    FolderListCreateFolderRequested event,
    Emitter<FolderListState> emit,
  ) async {
    final pending = PendingFolderCreation(
      parentFolderId: event.parentFolderId,
      displayName: event.displayName,
    );
    final before = state;
    if (before is FolderListLoaded) {
      emit(before.copyWith(pendingCreate: pending));
    }

    final result = await _createFolder(CreateFolderParams(
      parentFolderId: event.parentFolderId,
      displayName: event.displayName,
    ));
    if (isClosed) return;

    result.fold(
      (failure) {
        debugPrint('[FolderList] create "${event.displayName}" failed: '
            '${failure.runtimeType} — ${failure.message}');
        final current = state;
        if (current is FolderListLoaded) {
          emit(current.copyWith(pendingCreate: pending.withError(failure.message)));
        }
      },
      (folder) {
        _unconfirmedFolders[folder.id] = (folder: folder, misses: 0);
        final current = state;
        if (current is FolderListLoaded) {
          emit(current.copyWith(
            folders: _sorted(_insertFolder(current.folders, folder)),
            clearPendingCreate: true,
          ));
        }
        add(const FolderListLoadRequested());
      },
    );
  }

  void _onCreateFolderDismissed(
    FolderListCreateFolderDismissed event,
    Emitter<FolderListState> emit,
  ) {
    final current = state;
    if (current is! FolderListLoaded) return;
    emit(current.copyWith(clearPendingCreate: true));
  }

  /// Adds [folder] to [folders], bumping its parent's [childFolderCount] so
  /// the parent draws its disclosure arrow. A folder already in the list is
  /// left alone — the parent's count has already been accounted for.
  static List<EmailFolder> _insertFolder(
    List<EmailFolder> folders,
    EmailFolder folder,
  ) {
    if (folders.any((f) => f.id == folder.id)) return folders;
    return [
      for (final f in folders)
        if (f.id == folder.parentFolderId)
          f.copyWith(childFolderCount: f.childFolderCount + 1)
        else
          f,
      folder,
    ];
  }

  /// Merges every unconfirmed folder into [folders] without judging them, for
  /// the cached list — which is not the server's answer either way, so an
  /// omission there says nothing. Reached only when a load falls back to the
  /// cache on the account it already had folders for, i.e. after a fetch came
  /// back empty; the account-switch path clears the map first.
  List<EmailFolder> _withUnconfirmed(List<EmailFolder> folders) {
    var merged = folders;
    for (final entry in _unconfirmedFolders.values) {
      merged = _insertFolder(merged, entry.folder);
    }
    return merged;
  }

  /// Same merge, but against a list the *server* just gave us: a folder it
  /// names is confirmed and stops being tracked, and one it has omitted for
  /// [_unconfirmedFolderGrace] lists running is given up on.
  List<EmailFolder> _reconcileUnconfirmed(List<EmailFolder> folders) {
    if (_unconfirmedFolders.isEmpty) return folders;
    final serverIds = {for (final f in folders) f.id};
    var merged = folders;
    for (final id in _unconfirmedFolders.keys.toList()) {
      final entry = _unconfirmedFolders[id]!;
      if (serverIds.contains(id)) {
        _unconfirmedFolders.remove(id);
        continue;
      }
      if (entry.misses + 1 >= _unconfirmedFolderGrace) {
        debugPrint('[FolderList] giving up on unconfirmed folder '
            '"${entry.folder.displayName}" — the server has not listed it in '
            '$_unconfirmedFolderGrace fetches');
        _unconfirmedFolders.remove(id);
        continue;
      }
      _unconfirmedFolders[id] = (folder: entry.folder, misses: entry.misses + 1);
      merged = _insertFolder(merged, entry.folder);
    }
    return merged;
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
