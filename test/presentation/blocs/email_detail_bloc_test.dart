import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/services/eml_parser.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/usecases/check_sender_anomaly.dart';
import 'package:nightmail/domain/usecases/get_email.dart';
import 'package:nightmail/domain/usecases/merge_sender_addresses.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/presentation/blocs/email_detail/email_detail_bloc.dart';
import 'package:nightmail/presentation/blocs/email_detail/email_detail_event.dart';
import 'package:nightmail/presentation/blocs/email_detail/email_detail_state.dart';

import 'email_detail_bloc_test.mocks.dart';

Email _email(String id) => EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: 'body for $id',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026, 6, 1),
      importance: EmailImportance.normal,
    );

@GenerateMocks([GetEmail, CheckSenderAnomaly, MergeSenderAddresses, AccountManager])
void main() {
  late MockGetEmail mockGetEmail;
  late MockCheckSenderAnomaly mockCheckSenderAnomaly;
  late MockMergeSenderAddresses mockMergeSenderAddresses;
  late MockAccountManager mockAccountManager;
  late EmailDetailBloc bloc;

  setUpAll(() {
    provideDummy<Either<Failure, Email>>(Right(_email('dummy')));
    provideDummy<Either<Failure, SenderAnomalyResult?>>(const Right(null));
  });

  setUp(() {
    mockGetEmail = MockGetEmail();
    mockCheckSenderAnomaly = MockCheckSenderAnomaly();
    mockMergeSenderAddresses = MockMergeSenderAddresses();
    mockAccountManager = MockAccountManager();
    when(mockAccountManager.activeAccount).thenReturn(null);
    when(mockCheckSenderAnomaly(any)).thenAnswer((_) async => const Right(null));

    bloc = EmailDetailBloc(
      getEmail: mockGetEmail,
      emlParser: EmlParser(),
      checkSenderAnomaly: mockCheckSenderAnomaly,
      mergeSenderAddresses: mockMergeSenderAddresses,
      accountManager: mockAccountManager,
    );
  });

  tearDown(() async => bloc.close());

  // Regression: flutter_bloc runs on<Event> handlers concurrently by
  // default. Opening a slow/failing email and then immediately opening a
  // second, fast (cached) one starts two overlapping _onLoadRequested
  // calls — without a staleness guard, whichever happens to finish last
  // wins the final emitted state regardless of which the user actually
  // asked for last, so email 1's late failure could stomp email 2's
  // already-displayed content.
  test('a slow failing request for an earlier email does not overwrite a '
      'later, faster request that already loaded', () async {
    final slowCompleter = Completer<Either<Failure, Email>>();
    when(mockGetEmail(const GetEmailParams(id: 'email-1')))
        .thenAnswer((_) => slowCompleter.future);
    when(mockGetEmail(const GetEmailParams(id: 'email-2')))
        .thenAnswer((_) async => Right(_email('email-2')));

    bloc.add(const EmailDetailLoadRequested(emailId: 'email-1'));
    // email-1's fetch is still pending (slowCompleter not resolved yet).
    bloc.add(const EmailDetailLoadRequested(emailId: 'email-2'));

    final loaded = await bloc.stream.firstWhere((s) => s is EmailDetailLoaded)
        as EmailDetailLoaded;
    expect(loaded.email.id, 'email-2');

    // email-1's request finally resolves (as a failure) after the user has
    // already moved on to email-2 — it must not clobber the current state.
    slowCompleter.complete(const Left(NetworkFailure(message: 'timed out')));
    await pumpEventQueue();

    expect(bloc.state, isA<EmailDetailLoaded>());
    expect((bloc.state as EmailDetailLoaded).email.id, 'email-2');
  });

  test('loads normally when there is no overlapping request', () async {
    when(mockGetEmail(const GetEmailParams(id: 'email-1')))
        .thenAnswer((_) async => Right(_email('email-1')));

    bloc.add(const EmailDetailLoadRequested(emailId: 'email-1'));

    final loaded = await bloc.stream.firstWhere((s) => s is EmailDetailLoaded)
        as EmailDetailLoaded;
    expect(loaded.email.id, 'email-1');
  });
}
