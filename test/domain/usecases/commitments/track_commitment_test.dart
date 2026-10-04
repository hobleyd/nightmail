import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/repositories/commitment_repository.dart';
import 'package:nightmail/domain/usecases/commitments/commitment_ledger_changes.dart';
import 'package:nightmail/domain/usecases/commitments/track_commitment.dart';

import 'track_commitment_test.mocks.dart';

/// Tracking a message by hand: the row is built the way detection would
/// build it, an earlier Done is overridden, the message is marked scanned,
/// and the open pane is told.
@GenerateMocks([CommitmentRepository])
void main() {
  late MockCommitmentRepository ledger;
  late CommitmentLedgerChanges changes;
  late List<String> notified;
  late TrackCommitment track;

  const me = 'me@example.com';
  final now = DateTime(2026, 10, 5, 9);

  Email email({
    required String id,
    required String from,
    List<String> to = const [],
    List<String> cc = const [],
    String subject = 'Subject',
    String body = '',
    String? conversationId = 'conv',
  }) =>
      Email(
        id: id,
        subject: subject,
        from: EmailAddress(address: from, name: from.split('@').first),
        toRecipients: [for (final t in to) EmailAddress(address: t)],
        ccRecipients: [for (final t in cc) EmailAddress(address: t)],
        bodyPreview: '',
        body: body,
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: now.subtract(const Duration(hours: 3)),
        sentDateTime: now.subtract(const Duration(hours: 2)),
        importance: EmailImportance.normal,
        conversationId: conversationId,
      );

  TrackCommitmentParams params(
    Email e, {
    CommitmentKind kind = CommitmentKind.needsAction,
    CommitmentDue due = CommitmentDue.thisWeek,
  }) =>
      TrackCommitmentParams(
        accountId: 'acc',
        selfAddresses: const {me},
        email: e,
        kind: kind,
        due: due,
        now: now,
      );

  setUp(() {
    provideDummy<Either<Failure, Unit>>(Right(unit));
    ledger = MockCommitmentRepository();
    changes = CommitmentLedgerChanges();
    notified = [];
    changes.stream.listen(notified.add);
    when(ledger.saveCommitments(any)).thenAnswer((_) async => Right(unit));
    when(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));
    when(ledger.markScanned(
      accountId: anyNamed('accountId'),
      emailIds: anyNamed('emailIds'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));
    track = TrackCommitment(commitmentRepository: ledger, ledgerChanges: changes);
  });

  tearDown(() => changes.dispose());

  test('a received message becomes a row against its sender, keyed like a '
      'detection, with the user\'s own confidence', () async {
    final e = email(
      id: 'i1',
      from: 'jesse@client.com',
      to: [me],
      subject: 'Approval needed',
      body: 'Hi David,\n\nCould you approve the invoice today?\n\n'
          'On Mon, David wrote:\n> here it is',
    );

    final r = (await track(params(e, due: CommitmentDue.today)))
        .getOrElse((f) => fail('$f'));

    expect(r.id, 'needsAction:i1');
    expect(r.kind, CommitmentKind.needsAction);
    expect(r.status, CommitmentStatus.open);
    expect(r.counterpart.address, 'jesse@client.com');
    expect(r.subject, 'Approval needed');
    expect(r.snippet, 'Hi David, Could you approve the invoice today?');
    expect(r.due, CommitmentDue.today);
    expect(r.urgency, 2);
    expect(r.confidence, 1);
    expect(r.conversationId, 'conv');
    expect(r.emailDate, e.sentDateTime);
    expect(r.detectedAt, now);
    expect(r.estimatedMinutes, isNull); // the next scan sizes it

    final saved = verify(ledger.saveCommitments(captureAny)).captured.single
        as List<Commitment>;
    expect(saved.single, r);
    // Reopened in case the user had closed it before, and never shown to
    // the model again.
    verify(ledger.setStatus(
      accountId: 'acc',
      id: 'needsAction:i1',
      status: CommitmentStatus.open,
      now: now,
    )).called(1);
    verify(ledger.markScanned(
      accountId: 'acc',
      emailIds: argThat(equals(['i1']), named: 'emailIds'),
      now: now,
    )).called(1);
    await pumpEventQueue();
    expect(notified, ['acc']);
  });

  test('a sent message\'s counterpart is the first recipient who is not me',
      () async {
    final e = email(id: 's1', from: me, to: [me, 'sarah@client.com'], cc: ['x@y.com']);

    final r = (await track(params(e, kind: CommitmentKind.iOwe, due: CommitmentDue.none)))
        .getOrElse((f) => fail('$f'));

    expect(r.id, 'iOwe:s1');
    expect(r.counterpart.address, 'sarah@client.com');
    expect(r.urgency, 0);
  });

  test('urgency follows the due reading', () {
    expect(TrackCommitment.urgencyFor(CommitmentDue.today), 2);
    expect(TrackCommitment.urgencyFor(CommitmentDue.thisWeek), 1);
    expect(TrackCommitment.urgencyFor(CommitmentDue.later), 0);
    expect(TrackCommitment.urgencyFor(CommitmentDue.none), 0);
  });

  test('a ledger failure is the result and nobody is notified', () async {
    when(ledger.saveCommitments(any)).thenAnswer(
      (_) async => const Left(CacheFailure(message: 'disk full')),
    );

    final r = await track(params(email(id: 'i1', from: 'a@b.com')));

    expect(r.isLeft(), isTrue);
    verifyNever(ledger.markScanned(
      accountId: anyNamed('accountId'),
      emailIds: anyNamed('emailIds'),
      now: anyNamed('now'),
    ));
    await pumpEventQueue();
    expect(notified, isEmpty);
  });
}
