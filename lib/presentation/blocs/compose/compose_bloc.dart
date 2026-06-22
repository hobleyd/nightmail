import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/send_email.dart';
import 'compose_event.dart';
import 'compose_state.dart';

class ComposeBloc extends Bloc<ComposeEvent, ComposeState> {
  ComposeBloc({required this._sendEmail})
      : super(const ComposeInitial()) {
    on<ComposeSubmitted>(_onSubmitted);
  }

  final SendEmail _sendEmail;

  Future<void> _onSubmitted(
    ComposeSubmitted event,
    Emitter<ComposeState> emit,
  ) async {
    emit(const ComposeSending());
    final result = await _sendEmail(SendEmailParams(
      mode: event.mode,
      originalMessageId: event.originalMessageId,
      toAddresses: event.toAddresses,
      ccAddresses: event.ccAddresses,
      subject: event.subject,
      body: event.body,
      excludedAttachmentIds: event.excludedAttachmentIds,
      bodyType: event.bodyType,
      newAttachments: event.newAttachments,
    ));
    result.fold(
      (failure) => emit(ComposeError(message: failure.message)),
      (_) => emit(const ComposeSent()),
    );
  }
}
