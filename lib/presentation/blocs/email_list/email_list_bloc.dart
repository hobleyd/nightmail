import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/usecases/cache_emails.dart';
import '../../../domain/usecases/classify_emails.dart';
import '../../../domain/usecases/clear_email_cache_for_folder.dart';
import '../../../domain/usecases/delete_email.dart';
import '../../../domain/usecases/report_junk.dart';
import '../../../domain/usecases/search_emails.dart';
import '../../../domain/usecases/train_spam_filter.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../domain/usecases/empty_folder.dart';
import '../../../domain/usecases/get_cached_emails.dart';
import '../../../domain/usecases/get_emails.dart';
import '../../../domain/usecases/mark_email_as_read.dart';
import '../../../domain/usecases/move_email.dart';
import '../../../domain/usecases/record_known_senders.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/sync/outbox_drain_service.dart';
import '../../../infrastructure/sync/spam_db_sync_service.dart';
import 'email_list_event.dart';
import 'email_list_state.dart';

const _pageSize = 25;
const _defaultFolderKey = '__DEFAULT__';

class EmailListBloc extends Bloc<EmailListEvent, EmailListState> {
  EmailListBloc({
    required GetEmails getEmails,
    required GetCachedEmails getCachedEmails,
    required CacheEmails cacheEmails,
    required ClearEmailCacheForFolder clearEmailCacheForFolder,
    required MarkEmailAsRead markEmailAsRead,
    required MoveEmail moveEmail,
    required ReportJunk reportJunk,
    required DeleteEmail deleteEmail,
    required EmptyFolder emptyFolder,
    required AccountManager accountManager,
    required RecordKnownSenders recordKnownSenders,
    required ClassifyEmails classifyEmails,
    required TrainSpamFilter trainSpamFilter,
    required SearchEmails searchEmails,
    required SpamDbSyncService spamDbSyncService,
    required OutboxDrainService outboxDrainService,
  })  : _getEmails = getEmails,
        _getCachedEmails = getCachedEmails,
        _cacheEmails = cacheEmails,
        _clearEmailCacheForFolder = clearEmailCacheForFolder,
        _markEmailAsRead = markEmailAsRead,
        _moveEmail = moveEmail,
        _reportJunk = reportJunk,
        _deleteEmail = deleteEmail,
        _emptyFolder = emptyFolder,
        _accountManager = accountManager,
        _recordKnownSenders = recordKnownSenders,
        _classifyEmails = classifyEmails,
        _trainSpamFilter = trainSpamFilter,
        _searchEmails = searchEmails,
        _spamDbSyncService = spamDbSyncService,
        _outboxDrainService = outboxDrainService,
        super(const EmailListInitial()) {
    on<EmailListLoadRequested>(_onLoadRequested);
    on<EmailListLoadMoreRequested>(_onLoadMoreRequested);
    on<EmailListRefreshRequested>(_onRefreshRequested);
    on<EmailListCacheRefreshRequested>(_onCacheRefreshRequested);
    on<EmailListMarkReadRequested>(_onMarkReadRequested);
    on<EmailListMarkThreadReadRequested>(_onMarkThreadReadRequested);
    on<EmailListToggleConversation>(_onToggleConversation);
    on<EmailListEmailsMoved>(_onEmailsMoved);
    on<EmailListEmailDeleted>(_onEmailDeleted);
    on<EmailListEmailsBulkDeleted>(_onEmailsBulkDeleted);
    on<EmailListConversationDeleted>(_onConversationDeleted);
    on<EmailListJunkReported>(_onJunkReported);
    on<EmailListFolderEmptied>(_onFolderEmptied);
    on<EmailListCleared>(_onCleared);
    on<EmailListSearchModeActivated>(_onSearchModeActivated);
    on<EmailListSearchRequested>(_onSearchRequested);
    on<EmailListSearchCleared>(_onSearchCleared);
  }

  final GetEmails _getEmails;
  final GetCachedEmails _getCachedEmails;
  final CacheEmails _cacheEmails;
  final ClearEmailCacheForFolder _clearEmailCacheForFolder;
  final MarkEmailAsRead _markEmailAsRead;
  final MoveEmail _moveEmail;
  final ReportJunk _reportJunk;
  final DeleteEmail _deleteEmail;
  final EmptyFolder _emptyFolder;
  final AccountManager _accountManager;
  final RecordKnownSenders _recordKnownSenders;
  final ClassifyEmails _classifyEmails;
  final TrainSpamFilter _trainSpamFilter;
  final SearchEmails _searchEmails;
  final SpamDbSyncService _spamDbSyncService;
  final OutboxDrainService _outboxDrainService;

  /// Tracks the server-side skip offset for the current folder independently
  /// of the in-memory email count, which may be inflated by cross-folder
  /// conversation expansion on Graph accounts.
  int _serverOffset = 0;

  /// Bumped only by [_onLoadRequested] (a folder switch). Other handlers that
  /// emit after an await (refresh, load-more) capture it at the start and
  /// bail if it has changed by the time their await resolves, so a stale
  /// fetch for a folder the user has since navigated away from can't
  /// overwrite the newer folder's state. Events are handled with the default
  /// concurrent transformer, so without this multiple in-flight fetches for
  /// different folders can resolve out of order.
  int _activeRequestGeneration = 0;

  Future<void> _onLoadRequested(
    EmailListLoadRequested event,
    Emitter<EmailListState> emit,
  ) async {
    _serverOffset = 0;
    final myGeneration = ++_activeRequestGeneration;
    final accountId = _accountManager.activeAccount?.id;
    final folderKey = event.folderId ?? _defaultFolderKey;
    List<Email> cachedEmails = [];
    // Preserve in-flight Delete All tracking across a folder switch — it is
    // keyed by folder id, not tied to whichever folder happens to be on
    // screen, so navigating away must not make its shimmer vanish.
    final priorEmptyingIds =
        state is EmailListLoaded ? (state as EmailListLoaded).emptyingFolderIds : const <String>{};

    // Phase 1: serve cache immediately so the UI has content with no spinner
    if (accountId != null) {
      final cacheResult = await _getCachedEmails(GetCachedEmailsParams(
        accountId: accountId,
        folderId: folderKey,
      ));
      if (myGeneration != _activeRequestGeneration) return;
      cacheResult.fold(
        (_) => emit(const EmailListLoading()),
        (cached) {
          if (cached.isEmpty) {
            emit(const EmailListLoading());
          } else {
            cachedEmails = cached;
            emit(EmailListLoaded(
              emails: cached,
              hasMore: true,
              isLoadingFresh: true,
              currentFolderId: event.folderId,
              currentFolderName: event.folderDisplayName,
              emptyingFolderIds: priorEmptyingIds,
            ));
          }
        },
      );
    } else {
      emit(const EmailListLoading());
    }

    // Phase 2: network fetch — always attempted regardless of cache state
    final result = await _getEmails(GetEmailsParams(
      folderId: event.folderId,
      top: _pageSize,
    ));
    if (myGeneration != _activeRequestGeneration) return;

    List<Email>? loaded;
    result.fold(
      (failure) {
        if (cachedEmails.isNotEmpty) {
          // Keep cached emails visible; just clear the refresh indicator
          final s = state;
          if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
        } else {
          emit(EmailListError(message: failure.message));
        }
      },
      (freshEmails) {
        _serverOffset = _pageSize;
        loaded = freshEmails;
        // Merge: use fresh data for page-1 emails, keep cached beyond page 1.
        final freshIds = freshEmails.map((e) => e.id).toSet();
        final merged = [
          ...freshEmails,
          ...cachedEmails.where((e) => !freshIds.contains(e.id)),
        ];
        final s = state;
        emit(EmailListLoaded(
          emails: merged,
          hasMore: freshEmails.length >= _pageSize,
          isLoadingFresh: false,
          currentFolderId: event.folderId,
          currentFolderName: event.folderDisplayName,
          emptyingFolderIds: s is EmailListLoaded ? s.emptyingFolderIds : priorEmptyingIds,
        ));
        _recordSenders(freshEmails, event.folderDisplayName);
      },
    );
    if (loaded != null) {
      await _classifyAndTrainIfImap(emit, loaded!);
    }
  }

  Future<void> _onLoadMoreRequested(
    EmailListLoadMoreRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded || !current.hasMore || current.isLoadingMore) {
      return;
    }
    final myGeneration = _activeRequestGeneration;

    emit(current.copyWith(isLoadingMore: true));

    final result = await _getEmails(GetEmailsParams(
      folderId: current.currentFolderId,
      top: _pageSize,
      skip: _serverOffset,
    ));
    // Re-check: the user may have switched folders (bumping the generation
    // via _onLoadRequested) while this page was in flight. `current` here is
    // still the pre-await snapshot, so emitting unconditionally would splice
    // this page onto — or replace — whatever folder is now on screen.
    if (myGeneration != _activeRequestGeneration) return;

    List<Email>? loadedMore;
    result.fold(
      (failure) => emit(EmailListError(message: failure.message)),
      (newEmails) {
        _serverOffset += _pageSize;
        // Dedup: cross-folder expansion can return messages already in the list.
        final existingIds = current.emails.map((e) => e.id).toSet();
        final uniqueNew = newEmails.where((e) => !existingIds.contains(e.id)).toList();
        loadedMore = uniqueNew;
        emit(current.copyWith(
          emails: [...current.emails, ...uniqueNew],
          hasMore: newEmails.length >= _pageSize,
          isLoadingMore: false,
        ));
        _recordSenders(uniqueNew, current.currentFolderName);
      },
    );
    if (loadedMore != null) {
      await _classifyAndTrainIfImap(emit, loadedMore!);
    }
  }

  Future<void> _onRefreshRequested(
    EmailListRefreshRequested event,
    Emitter<EmailListState> emit,
  ) async {
    _serverOffset = 0;
    final myGeneration = _activeRequestGeneration;
    final prior = state is EmailListLoaded ? state as EmailListLoaded : null;
    final folderId = event.folderId ?? prior?.currentFolderId;
    final folderName = prior?.currentFolderName;
    final accountId = _accountManager.activeAccount?.id;

    if (prior != null) {
      emit(prior.copyWith(isLoadingFresh: true));
    }

    final result = await _getEmails(GetEmailsParams(
      folderId: folderId,
      top: _pageSize,
    ));
    // A folder switch (which bumps the generation via _onLoadRequested) while
    // this refresh was in flight means `folderId` no longer reflects what's
    // on screen — drop the stale result instead of overwriting the newer
    // folder's state.
    if (myGeneration != _activeRequestGeneration) return;

    List<Email>? refreshed;
    await result.fold(
      (failure) async {
        // Network failed — leave the existing (possibly cache-sourced) list
        // on screen untouched rather than wiping it out.
        final s = state;
        if (s is EmailListLoaded) {
          emit(s.copyWith(isLoadingFresh: false));
        } else {
          emit(EmailListError(message: failure.message));
        }
      },
      (emails) async {
        // Only clear stale cache rows once we have confirmed fresh data to
        // replace them with, so deleted/moved emails don't persist without
        // ever risking wiping the cache out from under an offline retry.
        // Clear then explicitly re-write the fresh page ourselves — the
        // repository's own cache write inside getEmails() above is a fire-
        // and-forget side effect that isn't ordered against this clear, so
        // relying on it here would race and could leave the folder's cache
        // empty after a successful refresh.
        if (accountId != null) {
          final key = folderId ?? _defaultFolderKey;
          await _clearEmailCacheForFolder(
              ClearEmailCacheForFolderParams(accountId: accountId, folderId: key));
          await _cacheEmails(CacheEmailsParams(
            accountId: accountId,
            folderId: key,
            emails: emails,
          ));
        }
        _serverOffset = _pageSize;
        refreshed = emails;
        final s = state;
        emit(EmailListLoaded(
          emails: emails,
          hasMore: emails.length >= _pageSize,
          currentFolderId: folderId,
          currentFolderName: folderName,
          emptyingFolderIds: s is EmailListLoaded ? s.emptyingFolderIds : const {},
        ));
        _recordSenders(emails, folderName);
      },
    );
    if (refreshed != null) {
      await _classifyAndTrainIfImap(emit, refreshed!);
    }
  }

  Future<void> _onCacheRefreshRequested(
    EmailListCacheRefreshRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final s = state;
    if (s is! EmailListLoaded) return;
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;

    final result = await _getCachedEmails(GetCachedEmailsParams(
      accountId: accountId,
      folderId: s.currentFolderId ?? _defaultFolderKey,
    ));
    result.fold((_) {}, (cached) {
      // Re-check after the await: the user may have switched folders while
      // this was in flight, and a stale repaint would flash the previous
      // folder's content over the one now on screen.
      final current = state;
      if (current is! EmailListLoaded ||
          current.currentFolderId != s.currentFolderId) {
        return;
      }
      emit(current.copyWith(emails: cached));
    });
  }

  Future<void> _onMarkReadRequested(
    EmailListMarkReadRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    final result = await _markEmailAsRead(
      MarkEmailAsReadParams(id: event.emailId, isRead: event.isRead),
    );

    result.fold(
      (_) {},
      (updated) {
        final updatedList = current.emails.map((e) {
          return e.id == updated.id ? updated : e;
        }).toList();
        emit(current.copyWith(emails: updatedList));
      },
    );
  }

  Future<void> _onMarkThreadReadRequested(
    EmailListMarkThreadReadRequested event,
    Emitter<EmailListState> emit,
  ) async {
    if (state is! EmailListLoaded) return;

    final updates = <String, Email>{};
    for (final id in event.emailIds) {
      final result = await _markEmailAsRead(
        MarkEmailAsReadParams(id: id, isRead: event.isRead),
      );
      result.fold((_) {}, (updated) => updates[updated.id] = updated);
    }
    if (updates.isEmpty) return;

    // Re-read state: it may have changed while the awaits were in flight.
    final latest = state;
    if (latest is! EmailListLoaded) return;
    final updatedList =
        latest.emails.map((e) => updates[e.id] ?? e).toList();
    emit(latest.copyWith(emails: updatedList));
  }

  void _onToggleConversation(
    EmailListToggleConversation event,
    Emitter<EmailListState> emit,
  ) {
    final current = state;
    if (current is! EmailListLoaded) return;

    final expanded = Set<String>.from(current.expandedConversationIds);
    if (expanded.contains(event.conversationId)) {
      expanded.remove(event.conversationId);
    } else {
      expanded.add(event.conversationId);
    }

    emit(current.copyWith(expandedConversationIds: expanded));
  }

  Future<void> _onEmailsMoved(
    EmailListEmailsMoved event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    // When a conversationId is present, remove the entire thread from view
    // (including cross-folder display emails not in emailIds). This prevents
    // the thread stub from reappearing after the optimistic update.
    final movedIds = event.emailIds.toSet();
    final removedEmails = event.conversationId != null
        ? current.emails
            .where((e) => e.conversationId == event.conversationId)
            .toList()
        : current.emails.where((e) => movedIds.contains(e.id)).toList();
    final filteredEmails = event.conversationId != null
        ? current.emails
            .where((e) => e.conversationId != event.conversationId)
            .toList()
        : current.emails.where((e) => !movedIds.contains(e.id)).toList();
    emit(current.copyWith(emails: filteredEmails));

    final results = await Future.wait(
      event.emailIds.map((id) => _moveEmail(MoveEmailParams(
            id: id,
            destinationFolderId: event.destinationFolderId,
          ))),
    );

    final failedIds = {
      for (var i = 0; i < event.emailIds.length; i++)
        if (results[i].isLeft()) event.emailIds[i],
    };
    if (failedIds.isNotEmpty) {
      final after = state;
      if (after is EmailListLoaded) {
        // For conversation moves, restore everything removed if any item
        // failed (the thread stub is still on the server). For individual
        // moves, restore only the ones that failed.
        final toRestore = event.conversationId != null
            ? removedEmails
            : removedEmails.where((e) => failedIds.contains(e.id)).toList();
        if (toRestore.isNotEmpty) {
          emit(after.copyWith(
            emails: [...after.emails, ...toRestore],
          ));
        }
      }
    }
  }

  Future<void> _onEmailDeleted(
    EmailListEmailDeleted event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;
    // Optimistically remove from list before API call completes
    emit(current.copyWith(
      emails: current.emails.where((e) => e.id != event.emailId).toList(),
    ));
    await _deleteEmail(DeleteEmailParams(id: event.emailId));
  }

  Future<void> _onEmailsBulkDeleted(
    EmailListEmailsBulkDeleted event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;
    final ids = event.emailIds.toSet();
    // Optimistically remove all selected emails before API calls complete
    emit(current.copyWith(
      emails: current.emails.where((e) => !ids.contains(e.id)).toList(),
    ));
    await Future.wait(
      event.emailIds.map((id) => _deleteEmail(DeleteEmailParams(id: id))),
    );
  }

  Future<void> _onConversationDeleted(
    EmailListConversationDeleted event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    final threadEmails = current.emails
        .where((e) => e.conversationId == event.conversationId)
        .toList();
    if (threadEmails.isEmpty) return;

    // Delete only the messages physically in the folder being viewed. Graph
    // and Gmail surface a thread's other-folder replies in this list, but
    // those have already been filed elsewhere and must be left alone. A null
    // folder id means an unscoped view (no folder to filter against), so the
    // whole thread is fair game; a null parentFolderId means the message came
    // straight from the folder query (augmented emails always carry a real
    // one), so it counts as in-folder.
    final folderId = current.currentFolderId;
    final toDelete = folderId == null
        ? threadEmails
        : threadEmails
            .where((e) =>
                e.parentFolderId == null || e.parentFolderId == folderId)
            .toList();
    if (toDelete.isEmpty) return;

    // Remove the whole thread from view: with its in-folder members gone the
    // conversation no longer belongs in this folder, so any augmented
    // other-folder rows should disappear with it rather than leave a stub.
    emit(current.copyWith(
      emails: current.emails
          .where((e) => e.conversationId != event.conversationId)
          .toList(),
    ));

    await Future.wait(
      toDelete.map((e) => _deleteEmail(DeleteEmailParams(id: e.id))),
    );
  }

  Future<void> _onJunkReported(
    EmailListJunkReported event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;
    final ids = event.emailIds.toSet();
    final junkEmails = current.emails.where((e) => ids.contains(e.id)).toList();
    emit(current.copyWith(
      emails: current.emails.where((e) => !ids.contains(e.id)).toList(),
    ));
    final results = await Future.wait(
      event.emailIds.map((id) => _reportJunk(ReportJunkParams(id: id))),
    );
    final failedIds = {
      for (var i = 0; i < event.emailIds.length; i++)
        if (results[i].isLeft()) event.emailIds[i],
    };
    if (failedIds.isNotEmpty) {
      final after = state;
      if (after is EmailListLoaded) {
        final failedEmails =
            junkEmails.where((e) => failedIds.contains(e.id)).toList();
        emit(after.copyWith(
          emails: [...after.emails, ...failedEmails],
        ));
      }
    }
    if (_accountManager.activeAccount is ImapAccount) {
      final accountId = _accountManager.activeAccount?.id;
      if (accountId != null && junkEmails.isNotEmpty) {
        // Training must finish writing before enqueuePush's next read of it.
        // The push itself is *not* run directly from here — it's enqueued
        // and drained by OutboxDrainService alongside this account's other
        // pending mutations, since ImapDatasourceImpl's one live connection
        // has no per-operation locking: a SPAMDB SELECT run directly from
        // here could still be in flight when some other flow selects a
        // different mailbox on that same connection, corrupting whichever
        // operation runs second. See SpamDbSyncService's class doc.
        await _trainSpamFilter(TrainSpamFilterParams(
          accountId: accountId,
          emails: junkEmails,
          isSpam: true,
        ));
        await _spamDbSyncService.enqueuePush(accountId);
        unawaited(_outboxDrainService.drainForAccount(accountId));
      }
    }
  }

  Future<void> _onFolderEmptied(
    EmailListFolderEmptied event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is EmailListLoaded) {
      final emptyingIds = {...current.emptyingFolderIds, event.folderId};
      emit(current.copyWith(
        emails: current.currentFolderId == event.folderId ? [] : current.emails,
        hasMore: current.currentFolderId == event.folderId ? false : current.hasMore,
        emptyingFolderIds: emptyingIds,
      ));
    }

    final result = await _emptyFolder(EmptyFolderParams(
      folderId: event.folderId,
      permanentDelete: event.permanentDelete,
    ));

    final after = state;
    if (after is EmailListLoaded) {
      emit(after.copyWith(
        emptyingFolderIds: after.emptyingFolderIds.difference({event.folderId}),
      ));
    }

    // A failed/partial empty (e.g. throttled partway through a large folder)
    // must not leave the optimistic "folder is empty" view above standing —
    // re-fetch so whatever is actually still on the server reappears.
    final afterClear = state;
    if (result.isLeft() &&
        afterClear is EmailListLoaded &&
        afterClear.currentFolderId == event.folderId) {
      final fetchResult = await _getEmails(GetEmailsParams(
        folderId: event.folderId,
        top: _pageSize,
      ));
      fetchResult.fold(
        (_) {},
        (emails) {
          _serverOffset = _pageSize;
          final s = state;
          if (s is EmailListLoaded) {
            emit(s.copyWith(emails: emails, hasMore: emails.length >= _pageSize));
          }
        },
      );
    }
  }

  void _onCleared(
    EmailListCleared event,
    Emitter<EmailListState> emit,
  ) {
    emit(const EmailListInitial());
  }

  Future<void> _classifyAndTrainIfImap(
    Emitter<EmailListState> emit,
    List<Email> emails,
  ) async {
    if (_accountManager.activeAccount is! ImapAccount) return;
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null || emails.isEmpty) return;

    final spamIds = await _classifyEmails(ClassifyEmailsParams(
      accountId: accountId,
      emails: emails,
    ));

    final current = state;
    if (current is EmailListLoaded && spamIds.isNotEmpty) {
      emit(current.copyWith(spamEmailIds: spamIds));
    }

    unawaited(_trainSpamFilter(TrainSpamFilterParams(
      accountId: accountId,
      emails: emails,
      isSpam: false,
    )));
  }

  void _onSearchModeActivated(
    EmailListSearchModeActivated event,
    Emitter<EmailListState> emit,
  ) {
    final current = state;
    if (current is EmailListLoaded) {
      emit(current.copyWith(isSearchMode: true));
    }
  }

  Future<void> _onSearchRequested(
    EmailListSearchRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    emit(current.copyWith(isLoadingFresh: true));

    final result = await _searchEmails(SearchEmailsParams(
      folderId: current.currentFolderId,
      query: event.query,
    ));

    result.fold(
      (failure) {
        final s = state;
        if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
      },
      (emails) => emit(current.copyWith(
        emails: emails,
        isLoadingFresh: false,
        isSearchMode: true,
        activeSearchQuery: event.query,
        hasMore: false,
      )),
    );
  }

  Future<void> _onSearchCleared(
    EmailListSearchCleared event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    final folderId = current.currentFolderId;
    final folderName = current.currentFolderName;

    emit(current.copyWith(
      isSearchMode: false,
      activeSearchQuery: null,
      isLoadingFresh: true,
    ));

    final result = await _getEmails(GetEmailsParams(
      folderId: folderId,
      top: _pageSize,
    ));

    result.fold(
      (failure) {
        final s = state;
        if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
      },
      (emails) {
        emit(EmailListLoaded(
          emails: emails,
          hasMore: emails.length == _pageSize,
          currentFolderId: folderId,
          currentFolderName: folderName,
          emptyingFolderIds: current.emptyingFolderIds,
        ));
        _recordSenders(emails, folderName);
      },
    );
  }

  void _recordSenders(List<Email> emails, String? folderName) {
    if (_isJunkFolder(folderName)) return;
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    unawaited(_recordKnownSenders(RecordKnownSendersParams(
      accountId: accountId,
      emails: emails,
    )));
  }

  static bool _isJunkFolder(String? name) {
    if (name == null) return false;
    return switch (name.toLowerCase()) {
      'junk' || 'junk email' || 'spam' => true,
      _ => false,
    };
  }
}
