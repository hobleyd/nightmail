import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/get_emails.dart';
import '../../../domain/usecases/mark_email_as_read.dart';
import 'email_list_event.dart';
import 'email_list_state.dart';

const _pageSize = 25;

class EmailListBloc extends Bloc<EmailListEvent, EmailListState> {
  EmailListBloc({
    required GetEmails getEmails,
    required MarkEmailAsRead markEmailAsRead,
  })  : _getEmails = getEmails,
        _markEmailAsRead = markEmailAsRead,
        super(const EmailListInitial()) {
    on<EmailListLoadRequested>(_onLoadRequested);
    on<EmailListLoadMoreRequested>(_onLoadMoreRequested);
    on<EmailListRefreshRequested>(_onRefreshRequested);
    on<EmailListMarkReadRequested>(_onMarkReadRequested);
  }

  final GetEmails _getEmails;
  final MarkEmailAsRead _markEmailAsRead;

  Future<void> _onLoadRequested(
    EmailListLoadRequested event,
    Emitter<EmailListState> emit,
  ) async {
    emit(const EmailListLoading());
    final result = await _getEmails(GetEmailsParams(
      folderId: event.folderId,
      top: _pageSize,
    ));
    result.fold(
      (failure) => emit(EmailListError(message: failure.message)),
      (emails) => emit(EmailListLoaded(
        emails: emails,
        hasMore: emails.length == _pageSize,
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
      (failure) => emit(EmailListError(message: failure.message)),
      (updated) {
        final updatedList = current.emails.map((e) {
          return e.id == updated.id ? updated : e;
        }).toList();
        emit(current.copyWith(emails: updatedList));
      },
    );
  }

}
