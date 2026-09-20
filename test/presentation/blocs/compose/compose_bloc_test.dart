import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/blocs/compose/compose_event.dart';
import 'package:nightmail/presentation/blocs/compose/compose_state.dart';

import 'compose_bloc_test.mocks.dart';

const _submitted = ComposeSubmitted(
  mode: ComposeMode.newEmail,
  toAddresses: ['someone@example.com'],
  subject: 'Hi',
  body: 'Hello there',
);

@GenerateMocks([SendEmail])
void main() {
  late MockSendEmail mockSendEmail;
  late ComposeBloc bloc;

  setUp(() {
    provideDummy<Either<Failure, Unit>>(const Right(unit));
    mockSendEmail = MockSendEmail();
    bloc = ComposeBloc(sendEmail: mockSendEmail);
  });

  tearDown(() => bloc.close());

  test('starts in ComposeInitial', () {
    expect(bloc.state, const ComposeInitial());
  });

  test('a successful send moves through Sending to Sent', () async {
    when(mockSendEmail(any)).thenAnswer((_) async => const Right(unit));

    bloc.add(_submitted);

    await expectLater(
      bloc.stream,
      emitsInOrder([const ComposeSending(), const ComposeSent()]),
    );
  });

  test('a failed send moves through Sending to Error with the failure '
      'message', () async {
    when(mockSendEmail(any))
        .thenAnswer((_) async => const Left(ServerFailure(message: 'boom')));

    bloc.add(_submitted);

    await expectLater(
      bloc.stream,
      emitsInOrder([
        const ComposeSending(),
        const ComposeError(message: 'boom'),
      ]),
    );
  });

  test('forwards every field of the event into SendEmailParams', () async {
    when(mockSendEmail(any)).thenAnswer((_) async => const Right(unit));

    bloc.add(const ComposeSubmitted(
      mode: ComposeMode.reply,
      originalMessageId: 'msg-1',
      toAddresses: ['a@example.com'],
      ccAddresses: ['b@example.com'],
      subject: 'Re: Hi',
      body: 'Reply body',
      excludedAttachmentIds: ['att-1'],
      bodyType: EmailBodyType.html,
      fromAccountId: 'acct-1',
    ));
    await bloc.stream.firstWhere((s) => s is! ComposeSending);

    final params = verify(mockSendEmail(captureAny)).captured.single
        as SendEmailParams;
    expect(params.mode, ComposeMode.reply);
    expect(params.originalMessageId, 'msg-1');
    expect(params.toAddresses, ['a@example.com']);
    expect(params.ccAddresses, ['b@example.com']);
    expect(params.subject, 'Re: Hi');
    expect(params.body, 'Reply body');
    expect(params.excludedAttachmentIds, ['att-1']);
    expect(params.bodyType, EmailBodyType.html);
    expect(params.fromAccountId, 'acct-1');
  });
}
