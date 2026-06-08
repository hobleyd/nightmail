import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/services/eml_parser.dart';
import '../../../domain/usecases/get_email.dart';
import 'email_detail_event.dart';
import 'email_detail_state.dart';

class EmailDetailBloc extends Bloc<EmailDetailEvent, EmailDetailState> {
  EmailDetailBloc({
    required this._getEmail,
    required this._emlParser,
  }) : super(const EmailDetailInitial()) {
    on<EmailDetailLoadRequested>(_onLoadRequested);
    on<EmailDetailLoadedFromEml>(_onLoadedFromEml);
    on<EmailDetailCleared>(_onCleared);
  }

  final GetEmail _getEmail;
  final EmlParser _emlParser;

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

  Future<void> _onLoadedFromEml(
    EmailDetailLoadedFromEml event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailLoading());
    try {
      final email = _emlParser.parse(
        event.bytes,
        id: event.sourceId ?? 'task-attachment',
      );
      emit(EmailDetailLoaded(email: email));
    } catch (e) {
      emit(EmailDetailError(message: 'Failed to parse email: $e'));
    }
  }

  Future<void> _onCleared(
    EmailDetailCleared event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailInitial());
  }
}
