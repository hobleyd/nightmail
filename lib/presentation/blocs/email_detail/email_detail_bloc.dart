import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/services/eml_parser.dart';
import '../../../domain/usecases/check_sender_anomaly.dart';
import '../../../domain/usecases/get_email.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'email_detail_event.dart';
import 'email_detail_state.dart';

class EmailDetailBloc extends Bloc<EmailDetailEvent, EmailDetailState> {
  EmailDetailBloc({
    required GetEmail getEmail,
    required EmlParser emlParser,
    required CheckSenderAnomaly checkSenderAnomaly,
    required AccountManager accountManager,
  })  : _getEmail = getEmail,
        _emlParser = emlParser,
        _checkSenderAnomaly = checkSenderAnomaly,
        _accountManager = accountManager,
        super(const EmailDetailInitial()) {
    on<EmailDetailLoadRequested>(_onLoadRequested);
    on<EmailDetailLoadedFromEml>(_onLoadedFromEml);
    on<EmailDetailCleared>(_onCleared);
  }

  final GetEmail _getEmail;
  final EmlParser _emlParser;
  final CheckSenderAnomaly _checkSenderAnomaly;
  final AccountManager _accountManager;

  Future<void> _onLoadRequested(
    EmailDetailLoadRequested event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailLoading());
    final result = await _getEmail(GetEmailParams(id: event.emailId));
    await result.fold(
      (failure) async => emit(EmailDetailError(message: failure.message)),
      (email) async {
        double? anomalyScore;
        final name = email.from.name;
        final accountId = _accountManager.activeAccount?.id;
        if (name != null && name.isNotEmpty && accountId != null) {
          final check = await _checkSenderAnomaly(CheckSenderAnomalyParams(
            accountId: accountId,
            fromAddress: email.from.address,
            fromName: name,
          ));
          anomalyScore = check.fold((_) => null, (s) => s);
        }
        emit(EmailDetailLoaded(email: email, senderAnomalyScore: anomalyScore));
      },
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
