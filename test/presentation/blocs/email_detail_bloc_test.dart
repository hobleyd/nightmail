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

Email _email(String id, {bool isRead = true, bool isFlagged = false}) =>
    EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: 'body for $id',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      isFlagged: isFlagged,
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

  // The pane used to build from this bloc alone, which never heard about a
  // poll — so a message read, flagged or moved on another machine left it
  // showing a stale copy, and the folder-count deltas its delete sends were
  // computed from that copy.
  group('EmailDetailRefreshRequested', () {
    Future<void> open(String id) async {
      when(mockGetEmail(GetEmailParams(id: id)))
          .thenAnswer((_) async => Right(_email(id)));
      bloc.add(EmailDetailLoadRequested(emailId: id));
      await bloc.stream.firstWhere((s) => s is EmailDetailLoaded);
    }

    test('replaces the open message in place, without a loading state',
        () async {
      await open('email-1');
      when(mockGetEmail(const GetEmailParams(id: 'email-1'))).thenAnswer(
          (_) async => Right(_email('email-1', isRead: false, isFlagged: true)));

      final seen = <EmailDetailState>[];
      final sub = bloc.stream.listen(seen.add);
      bloc.add(const EmailDetailRefreshRequested(emailId: 'email-1'));
      await pumpEventQueue();
      await sub.cancel();

      expect(seen.whereType<EmailDetailLoading>(), isEmpty,
          reason: 'a spinner would take the message off screen mid-read');
      final state = bloc.state as EmailDetailLoaded;
      expect(state.email.isFlagged, isTrue);
      expect(state.email.isRead, isFalse);
    });

    test('a failed refresh leaves the message on screen', () async {
      await open('email-1');
      when(mockGetEmail(const GetEmailParams(id: 'email-1'))).thenAnswer(
          (_) async => const Left(NetworkFailure(message: 'No network')));

      bloc.add(const EmailDetailRefreshRequested(emailId: 'email-1'));
      await pumpEventQueue();

      expect(bloc.state, isA<EmailDetailLoaded>());
      expect((bloc.state as EmailDetailLoaded).email.id, 'email-1');
    });

    // A poll can land a beat after the user has opened something else. Refresh
    // is not a way to open a message, so it must not resurrect the old one.
    test('a refresh for anything but the open message is ignored', () async {
      await open('email-1');
      clearInteractions(mockGetEmail);

      bloc.add(const EmailDetailRefreshRequested(emailId: 'email-2'));
      await pumpEventQueue();

      verifyNever(mockGetEmail(any));
      expect((bloc.state as EmailDetailLoaded).email.id, 'email-1');
    });
  });
}
