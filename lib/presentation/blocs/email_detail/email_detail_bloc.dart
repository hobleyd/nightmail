import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/get_email.dart';
import 'email_detail_event.dart';
import 'email_detail_state.dart';

class EmailDetailBloc extends Bloc<EmailDetailEvent, EmailDetailState> {
  EmailDetailBloc({required GetEmail getEmail})
      : _getEmail = getEmail,
        super(const EmailDetailInitial()) {
    on<EmailDetailLoadRequested>(_onLoadRequested);
    on<EmailDetailCleared>(_onCleared);
  }

  final GetEmail _getEmail;

  Future<void> _onLoadRequested(
    EmailDetailLoadRequested event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailLoading());
    final result = await _getEmail(GetEmailParams(id: event.emailId));
    result.fold(
      (failure) => emit(EmailDetailError(message: failure.message)),
      (email) => emit(EmailDetailLoaded(email: email)),
    );
  }

  Future<void> _onCleared(
    EmailDetailCleared event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailInitial());
  }
}
