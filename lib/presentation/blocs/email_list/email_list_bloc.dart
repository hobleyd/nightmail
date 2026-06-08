import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/usecases/delete_email.dart';
import '../../../domain/usecases/empty_folder.dart';
import '../../../domain/usecases/get_cached_emails.dart';
import '../../../domain/usecases/get_emails.dart';
import '../../../domain/usecases/mark_email_as_read.dart';
import '../../../domain/usecases/move_email.dart';
import '../../../domain/usecases/record_known_senders.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'email_list_event.dart';
import 'email_list_state.dart';

const _pageSize = 25;
const _defaultFolderKey = '__DEFAULT__';

class EmailListBloc extends Bloc<EmailListEvent, EmailListState> {
  EmailListBloc({
    required GetEmails getEmails,
    required GetCachedEmails getCachedEmails,
    required MarkEmailAsRead markEmailAsRead,
    required MoveEmail moveEmail,
    required DeleteEmail deleteEmail,
    required EmptyFolder emptyFolder,
    required AccountManager accountManager,
    required RecordKnownSenders recordKnownSenders,
  })  : _getEmails = getEmails,
        _getCachedEmails = getCachedEmails,
        _markEmailAsRead = markEmailAsRead,
        _moveEmail = moveEmail,
        _deleteEmail = deleteEmail,
        _emptyFolder = emptyFolder,
        _accountManager = accountManager,
        _recordKnownSenders = recordKnownSenders,
        super(const EmailListInitial()) {
    on<EmailListLoadRequested>(_onLoadRequested);
    on<EmailListLoadMoreRequested>(_onLoadMoreRequested);
    on<EmailListRefreshRequested>(_onRefreshRequested);
    on<EmailListMarkReadRequested>(_onMarkReadRequested);
    on<EmailListToggleConversation>(_onToggleConversation);
    on<EmailListEmailsMoved>(_onEmailsMoved);
    on<EmailListEmailDeleted>(_onEmailDeleted);
    on<EmailListEmailsBulkDeleted>(_onEmailsBulkDeleted);
    on<EmailListFolderEmptied>(_onFolderEmptied);
  }

  final GetEmails _getEmails;
  final GetCachedEmails _getCachedEmails;
  final MarkEmailAsRead _markEmailAsRead;
  final MoveEmail _moveEmail;
  final DeleteEmail _deleteEmail;
  final EmptyFolder _emptyFolder;
  final AccountManager _accountManager;
  final RecordKnownSenders _recordKnownSenders;

  Future<void> _onLoadRequested(
    EmailListLoadRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final accountId = _accountManager.activeAccount?.id;
    final folderKey = event.folderId ?? _defaultFolderKey;
    bool hasCachedData = false;

    // Phase 1: serve cache immediately so the UI has content with no spinner
    if (accountId != null) {
      final cacheResult = await _getCachedEmails(GetCachedEmailsParams(
        accountId: accountId,
        folderId: folderKey,
      ));
      cacheResult.fold(
        (_) => emit(const EmailListLoading()),
        (cached) {
          if (cached.isEmpty) {
            emit(const EmailListLoading());
          } else {
            hasCachedData = true;
            emit(EmailListLoaded(
              emails: cached,
              hasMore: true,
              isLoadingFresh: true,
              currentFolderId: event.folderId,
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

    result.fold(
      (failure) {
        if (hasCachedData) {
          // Keep cached emails visible; just clear the refresh indicator
          final s = state;
          if (s is EmailListLoaded) emit(s.copyWith(isLoadingFresh: false));
        } else {
          emit(EmailListError(message: failure.message));
        }
      },
      (emails) {
        emit(EmailListLoaded(
          emails: emails,
          hasMore: emails.length == _pageSize,
          isLoadingFresh: false,
          currentFolderId: event.folderId,
        ));
        _recordSenders(emails);
      },
    );
  }

  Future<void> _onLoadMoreRequested(
    EmailListLoadMoreRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final current = state;
    if (current is! EmailListLoaded || !current.hasMore || current.isLoadingMore) {
      return;
    }

    emit(current.copyWith(isLoadingMore: true));

    final result = await _getEmails(GetEmailsParams(
      folderId: current.currentFolderId,
      top: _pageSize,
      skip: current.emails.length,
    ));

    result.fold(
      (failure) => emit(EmailListError(message: failure.message)),
      (newEmails) {
        emit(current.copyWith(
          emails: [...current.emails, ...newEmails],
          hasMore: newEmails.length == _pageSize,
          isLoadingMore: false,
        ));
        _recordSenders(newEmails);
      },
    );
  }

  Future<void> _onRefreshRequested(
    EmailListRefreshRequested event,
    Emitter<EmailListState> emit,
  ) async {
    final folderId = event.folderId ??
        (state is EmailListLoaded
            ? (state as EmailListLoaded).currentFolderId
            : null);

    final result = await _getEmails(GetEmailsParams(
      folderId: folderId,
      top: _pageSize,
    ));

    result.fold(
      (failure) => emit(EmailListError(message: failure.message)),
      (emails) {
        emit(EmailListLoaded(
          emails: emails,
          hasMore: emails.length == _pageSize,
          currentFolderId: folderId,
        ));
        _recordSenders(emails);
      },
    );
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
    final ids = event.emailIds.toSet();
    emit(current.copyWith(
      emails: current.emails.where((e) => !ids.contains(e.id)).toList(),
    ));
    await Future.wait(
      event.emailIds.map((id) => _moveEmail(MoveEmailParams(
            id: id,
            destinationFolderId: event.destinationFolderId,
          ))),
    );
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

    await _emptyFolder(EmptyFolderParams(
      folderId: event.folderId,
      permanentDelete: event.permanentDelete,
    ));

    final after = state;
    if (after is EmailListLoaded) {
      emit(after.copyWith(
        emptyingFolderIds: after.emptyingFolderIds.difference({event.folderId}),
      ));
    }
  }

  void _recordSenders(List<Email> emails) {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    unawaited(_recordKnownSenders(RecordKnownSendersParams(
      accountId: accountId,
      emails: emails,
    )));
  }
}
