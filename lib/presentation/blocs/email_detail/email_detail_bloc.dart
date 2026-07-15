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

  // flutter_bloc runs on<Event> handlers concurrently by default: opening an
  // email that needs a slow/failing network fetch, then immediately opening
  // a second (cached, fast) one, starts two overlapping _onLoadRequested
  // calls. Without this guard, whichever finishes last wins regardless of
  // which the user is actually looking at — so the first email's late
  // failure could overwrite the second email's already-displayed content.
  String? _latestRequestedEmailId;

  Future<void> _onLoadRequested(
    EmailDetailLoadRequested event,
    Emitter<EmailDetailState> emit,
  ) async {
    _latestRequestedEmailId = event.emailId;
    emit(const EmailDetailInitial());
    emit(const EmailDetailLoading());
    final result = await _getEmail(GetEmailParams(id: event.emailId));
    if (_latestRequestedEmailId != event.emailId) return;
    await result.fold(
      (failure) async => emit(EmailDetailError(message: failure.message)),
      (email) async {
        final name = email.from.name;
        final activeAccount = _accountManager.activeAccount;
        final accountId = activeAccount?.id;
        final accountDomain = _domainOf(activeAccount?.emailAddress);
        final senderDomain = _domainOf(email.from.address);
        final isInternal = accountDomain != null && accountDomain == senderDomain;
        final senderAnomaly = (name != null && name.isNotEmpty && accountId != null && !isInternal)
            ? await _checkSenderAnomaly(CheckSenderAnomalyParams(
                accountId: accountId,
                fromAddress: email.from.address,
                fromName: name,
              )).then((r) => r.fold((_) => null, (s) => s))
            : null;
        if (_latestRequestedEmailId != event.emailId) return;
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
    final accountDomain = _domainOf(_accountManager.activeAccount?.emailAddress);
    final senderDomain = _domainOf(current.email.from.address);
    final isInternal = accountDomain != null && accountDomain == senderDomain;
    final updatedAnomaly = (name != null && name.isNotEmpty && !isInternal)
        ? await _checkSenderAnomaly(CheckSenderAnomalyParams(
              accountId: accountId,
              fromAddress: current.email.from.address,
              fromName: name,
            )).then((r) => r.fold((_) => null, (s) => s))
        : null;

    emit(EmailDetailLoaded(
        email: current.email, senderAnomaly: updatedAnomaly));
  }

  static String? _domainOf(String? email) {
    if (email == null) return null;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
  }
}
