import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/services/eml_parser.dart';
import '../../../domain/usecases/check_sender_anomaly.dart';
import '../../../domain/usecases/get_email.dart';
import '../../../domain/usecases/merge_sender_addresses.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'email_detail_event.dart';
import 'email_detail_state.dart';

class EmailDetailBloc extends Bloc<EmailDetailEvent, EmailDetailState> {
  EmailDetailBloc({
    required GetEmail getEmail,
    required EmlParser emlParser,
    required CheckSenderAnomaly checkSenderAnomaly,
    required MergeSenderAddresses mergeSenderAddresses,
    required AccountManager accountManager,
  })  : _getEmail = getEmail,
        _emlParser = emlParser,
        _checkSenderAnomaly = checkSenderAnomaly,
        _mergeSenderAddresses = mergeSenderAddresses,
        _accountManager = accountManager,
        super(const EmailDetailInitial()) {
    on<EmailDetailLoadRequested>(_onLoadRequested);
    on<EmailDetailLoadedFromEml>(_onLoadedFromEml);
    on<EmailDetailCleared>(_onCleared);
    on<EmailDetailMergeSenderRequested>(_onMergeSenderRequested);
  }

  final GetEmail _getEmail;
  final EmlParser _emlParser;
  final CheckSenderAnomaly _checkSenderAnomaly;
  final MergeSenderAddresses _mergeSenderAddresses;
  final AccountManager _accountManager;

  Future<void> _onLoadRequested(
    EmailDetailLoadRequested event,
    Emitter<EmailDetailState> emit,
  ) async {
    emit(const EmailDetailInitial());
    emit(const EmailDetailLoading());
    final result = await _getEmail(GetEmailParams(id: event.emailId));
    await result.fold(
      (failure) async => emit(EmailDetailError(message: failure.message)),
      (email) async {
        final name = email.from.name;
        final accountId = _accountManager.activeAccount?.id;
        final senderAnomaly = (name != null && name.isNotEmpty && accountId != null)
            ? await _checkSenderAnomaly(CheckSenderAnomalyParams(
                accountId: accountId,
                fromAddress: email.from.address,
                fromName: name,
              )).then((r) => r.fold((_) => null, (s) => s))
            : null;
        emit(EmailDetailLoaded(email: email, senderAnomaly: senderAnomaly));
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

  Future<void> _onMergeSenderRequested(
    EmailDetailMergeSenderRequested event,
    Emitter<EmailDetailState> emit,
  ) async {
    final current = state;
    if (current is! EmailDetailLoaded) return;
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;

    await _mergeSenderAddresses(MergeSenderAddressesParams(
      accountId: accountId,
      address1: current.email.from.address,
      address2: event.matchAddress,
    ));

    final name = current.email.from.name;
    final updatedAnomaly = (name != null && name.isNotEmpty)
        ? await _checkSenderAnomaly(CheckSenderAnomalyParams(
              accountId: accountId,
              fromAddress: current.email.from.address,
              fromName: name,
            )).then((r) => r.fold((_) => null, (s) => s))
        : null;

    emit(EmailDetailLoaded(
        email: current.email, senderAnomaly: updatedAnomaly));
  }
}
