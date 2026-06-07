import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/get_cached_emails.dart';
import '../../../domain/usecases/get_emails.dart';
import '../../../domain/usecases/mark_email_as_read.dart';
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
    required AccountManager accountManager,
  })  : _getEmails = getEmails,
        _getCachedEmails = getCachedEmails,
        _markEmailAsRead = markEmailAsRead,
        _accountManager = accountManager,
        super(const EmailListInitial()) {
    on<EmailListLoadRequested>(_onLoadRequested);
    on<EmailListLoadMoreRequested>(_onLoadMoreRequested);
    on<EmailListRefreshRequested>(_onRefreshRequested);
    on<EmailListMarkReadRequested>(_onMarkReadRequested);
    on<EmailListToggleConversation>(_onToggleConversation);
    on<EmailListEmailDeleted>(_onEmailDeleted);
  }

  final GetEmails _getEmails;
  final GetCachedEmails _getCachedEmails;
  final MarkEmailAsRead _markEmailAsRead;
  final AccountManager _accountManager;

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
      (emails) => emit(EmailListLoaded(
        emails: emails,
        hasMore: emails.length == _pageSize,
        isLoadingFresh: false,
        currentFolderId: event.folderId,
      )),
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
      (newEmails) => emit(current.copyWith(
        emails: [...current.emails, ...newEmails],
        hasMore: newEmails.length == _pageSize,
        isLoadingMore: false,
      )),
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
      (emails) => emit(EmailListLoaded(
        emails: emails,
        hasMore: emails.length == _pageSize,
        currentFolderId: folderId,
      )),
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

  void _onEmailDeleted(
    EmailListEmailDeleted event,
    Emitter<EmailListState> emit,
  ) {
    final current = state;
    if (current is! EmailListLoaded) return;
    emit(current.copyWith(
      emails: current.emails.where((e) => e.id != event.emailId).toList(),
    ));
  }
}
