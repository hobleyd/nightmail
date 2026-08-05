import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/usecases/cache_emails.dart';
import '../../../domain/usecases/classify_emails.dart';
import '../../../domain/usecases/clear_email_cache_for_folder.dart';
import '../../../domain/usecases/delete_email.dart';
import '../../../domain/usecases/get_conversation_thread.dart';
import '../../../domain/usecases/get_email.dart';
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
    required GetEmail getEmail,
    required GetConversationThread getConversationThread,
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
        _getEmail = getEmail,
        _getConversationThread = getConversationThread,
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
    on<EmailListThreadFocusRequested>(_onThreadFocusRequested);
    on<EmailListThreadFocusCleared>(_onThreadFocusCleared);
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
  final GetEmail _getEmail;
  final GetConversationThread _getConversationThread;
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
    final prior = state is EmailListLoaded ? state as EmailListLoaded : null;

    // The list may be showing a single conversation rather than the folder.
    // Refresh is also fired periodically in the background, so falling
    // through here would silently swap the thread for the folder listing.
    if (prior != null && prior.focusedThreadId != null) {
      await _refreshFocusedThread(prior, emit);
      return;
    }

    _serverOffset = 0;
    final myGeneration = _activeRequestGeneration;
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
    // Search results and a focused thread aren't the folder's contents —
    // repainting them from the folder cache would wipe out what the user is
    // looking at.
    if (!s.isShowingFolder) return;
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

    // Move only the messages the folder being viewed actually holds. Both Graph
    // and Gmail surface a thread's other-folder messages in this list — replies
    // already filed elsewhere, and the copies in Sent — and filing the thread
    // out of this folder must not drag those along. Same rule the delete path
    // applies; see [Email.isMovableFrom].
    final folderId = current.currentFolderId;
    final byId = {for (final e in current.emails) e.id: e};
    final idsToMove = event.emailIds
        .where((id) => byId[id]?.isMovableFrom(folderId) ?? true)
        .toList();

    // Nothing of this selection is in this folder: it is on screen purely as
    // other-folder context. Leave both the server and the list alone rather
    // than hiding messages that no move would have relocated.
    if (idsToMove.isEmpty) return;

    // When a conversationId is present, remove the entire thread from view
    // (including the cross-folder rows just spared above). With its in-folder
    // members gone the conversation no longer belongs in this folder, so the
    // rows kept on screen purely as context should go with it rather than
    // leave a stub that reappears after the optimistic update.
    final movedIds = idsToMove.toSet();
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
      idsToMove.map((id) => _moveEmail(MoveEmailParams(
            id: id,
            destinationFolderId: event.destinationFolderId,
          ))),
    );

    final failedIds = {
      for (var i = 0; i < idsToMove.length; i++)
        if (results[i].isLeft()) idsToMove[i],
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

    // Delete only the messages the folder being viewed actually holds. Graph
    // and Gmail both surface a thread's other-folder messages in this list —
    // replies already filed elsewhere, and the copies in Sent — and deleting
    // the thread out of this folder must not take those with it. See
    // [Email.isDeletableFrom] for the rule.
    final folderId = current.currentFolderId;
    final toDelete =
        threadEmails.where((e) => e.isDeletableFrom(folderId)).toList();
    // Nothing of this thread is in this folder: it is on screen purely as
    // other-folder context. Leave both the server and the list alone rather
    // than hiding a thread that no delete would have removed.
    if (toDelete.isEmpty) return;

    // Remove the whole thread from view: with its in-folder members gone the
    // conversation no longer belongs in this folder, so any augmented
    // other-folder rows should disappear with it rather than leave a stub.
    emit(current.copyWith(
      emails: current.emails
          .where((e) => e.conversationId != event.conversationId)
          .toList(),
    ));

    final results = await Future.wait(
      toDelete.map((e) => _deleteEmail(DeleteEmailParams(id: e.id))),
    );

    // Put back what the server still holds. Anything that failed is plainly
    // still there, and so are the other-folder rows hidden alongside it — the
    // thread still has members in this folder, so it still belongs on screen.
    final deletedIds = {
      for (var i = 0; i < toDelete.length; i++)
        if (results[i].isRight()) toDelete[i].id,
    };
    if (deletedIds.length == toDelete.length) return;
    final after = state;
    // The list has moved on — another folder is on screen, so these rows have
    // no business being put back into it. Whatever survived is still on the
    // server and will reappear the next time this folder is read.
    if (after is! EmailListLoaded || after.currentFolderId != folderId) return;
    final onScreen = after.emails.map((e) => e.id).toSet();
    final toRestore = threadEmails
        .where((e) => !deletedIds.contains(e.id) && !onScreen.contains(e.id))
        .toList();
    if (toRestore.isEmpty) return;
    emit(after.copyWith(emails: [...after.emails, ...toRestore]));
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
        focusedThreadId: null,
        focusedThreadSubject: null,
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

  Future<void> _onThreadFocusRequested(
    EmailListThreadFocusRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded) return;

    // Focusing a thread is a view change like a folder switch: bump the
    // generation so a folder fetch already in flight can't land on top of it.
    final myGeneration = ++_activeRequestGeneration;
    emit(current.copyWith(isLoadingFresh: true));

    // The email is usually already on screen (a task made from the inbox
    // email being viewed), but it may equally live in a folder that isn't
    // loaded — fall back to fetching it by id.
    var anchor = _emailInList(current.emails, event.emailId);
    if (anchor == null) {
      final result = await _getEmail(GetEmailParams(id: event.emailId));
      if (myGeneration != _activeRequestGeneration) return;
      anchor = result.fold((_) => null, (email) => email);
    }
    if (anchor == null) {
      final s = state;
      if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
      return;
    }

    final threadId = anchor.conversationId ?? anchor.id;
    final thread = await _threadFor(anchor, current.emails);
    if (myGeneration != _activeRequestGeneration) return;

    final s = state;
    if (s is! EmailListLoaded) return;
    emit(s.copyWith(
      emails: thread,
      hasMore: false,
      isLoadingMore: false,
      isLoadingFresh: false,
      // Always open — seeing the messages is the whole point of focusing.
      expandedConversationIds: {...s.expandedConversationIds, threadId},
      focusedThreadId: threadId,
      focusedThreadSubject: anchor.subject,
      // A thread replaces search results; don't leave a stale query behind.
      isSearchMode: false,
      activeSearchQuery: null,
    ));
  }

  Future<void> _onThreadFocusCleared(
    EmailListThreadFocusCleared event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded || current.focusedThreadId == null) return;

    final myGeneration = ++_activeRequestGeneration;
    final folderId = current.currentFolderId;
    final folderName = current.currentFolderName;

    emit(current.copyWith(
      focusedThreadId: null,
      focusedThreadSubject: null,
      isLoadingFresh: true,
    ));

    _serverOffset = 0;
    final result = await _getEmails(GetEmailsParams(
      folderId: folderId,
      top: _pageSize,
    ));
    if (myGeneration != _activeRequestGeneration) return;

    result.fold(
      (failure) {
        final s = state;
        if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
      },
      (emails) {
        _serverOffset = _pageSize;
        emit(EmailListLoaded(
          emails: emails,
          hasMore: emails.length >= _pageSize,
          currentFolderId: folderId,
          currentFolderName: folderName,
          emptyingFolderIds: current.emptyingFolderIds,
        ));
        _recordSenders(emails, folderName);
      },
    );
  }

  /// Re-fetches the thread currently on screen, leaving focus mode intact.
  Future<void> _refreshFocusedThread(
    EmailListLoaded current,
    Emitter<EmailListState> emit,
  ) async {
    final threadId = current.focusedThreadId;
    if (threadId == null) return;

    final myGeneration = _activeRequestGeneration;
    emit(current.copyWith(isLoadingFresh: true));

    final result = await _getConversationThread(GetConversationThreadParams(
      conversationId: threadId,
      folderId: _folderHintFor(current),
    ));
    if (myGeneration != _activeRequestGeneration) return;

    final s = state;
    if (s is! EmailListLoaded || s.focusedThreadId != threadId) return;
    result.fold(
      (_) => emit(s.copyWith(isLoadingFresh: false)),
      (emails) => emit(s.copyWith(
        // An empty result means the lookup found nothing, not that the thread
        // vanished — keep showing what's there rather than emptying the pane.
        emails: emails.isEmpty ? s.emails : emails,
        hasMore: false,
        isLoadingFresh: false,
      )),
    );
  }

  /// Every message in [anchor]'s conversation, merged with any thread members
  /// already on screen. A provider fetch can fail or come back partial, and
  /// the anchor must always be present since the reading pane is showing it.
  Future<List<Email>> _threadFor(Email anchor, List<Email> onScreen) async {
    final conversationId = anchor.conversationId;
    if (conversationId == null) return [anchor];

    final result = await _getConversationThread(GetConversationThreadParams(
      conversationId: conversationId,
      folderId: anchor.parentFolderId,
    ));
    final fetched = result.fold((_) => const <Email>[], (emails) => emails);

    final byId = <String, Email>{for (final e in fetched) e.id: e};
    for (final e in onScreen) {
      if (e.conversationId == conversationId) byId.putIfAbsent(e.id, () => e);
    }
    byId.putIfAbsent(anchor.id, () => anchor);
    return byId.values.toList();
  }

  /// Folder to scope a thread lookup to, for providers that need one (IMAP).
  static String? _folderHintFor(EmailListLoaded state) {
    for (final email in state.emails) {
      final parent = email.parentFolderId;
      if (parent != null) return parent;
    }
    return state.currentFolderId;
  }

  static Email? _emailInList(List<Email> emails, String id) {
    for (final email in emails) {
      if (email.id == id) return email;
    }
    return null;
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
