import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_decision.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/repositories/ai/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/domain/repositories/commitment_repository.dart';
import 'package:nightmail/domain/usecases/commitments/detect_commitments.dart';

import 'detect_commitments_test.mocks.dart';

@GenerateMocks([
  AiSettingsRepository,
  AiInferenceRepository,
  CommitmentRepository,
])
void main() {
  late MockAiSettingsRepository settings;
  late MockAiInferenceRepository inference;
  late MockCommitmentRepository ledger;
  late DetectCommitments detect;

  /// What `saveCommitments` has been handed; `getCommitments` serves it back
  /// so the resolution pass sees what the scan just wrote.
  late List<Commitment> saved;

  const me = 'me@example.com';
  const account = 'acc-1';
  final now = DateTime(2026, 10, 2, 9);

  Email email({
    required String id,
    required String from,
    List<String> to = const [],
    String subject = 'Subject',
    String body = '',
    String preview = '',
    String? conversationId,
    required DateTime date,
  }) {
    return Email(
      id: id,
      subject: subject,
      from: EmailAddress(address: from, name: from.split('@').first),
      toRecipients: [for (final t in to) EmailAddress(address: t)],
      ccRecipients: const [],
      bodyPreview: preview,
      body: body,
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: date,
      sentDateTime: date,
      importance: EmailImportance.normal,
      conversationId: conversationId,
    );
  }

  AiDecisionResponse answers({
    double commits = 0,
    double requests = 0,
    double needsAction = 0,
    double bulk = 0,
    String due = 'none',
    double urgency = 0,
  }) {
    return AiDecisionResponse(
      model: 'jev-1.13.0',
      answers: {
        'commits': AiDecisionAnswer(
          type: AiDecisionQuestionType.noul,
          probability: commits,
        ),
        'requests': AiDecisionAnswer(
          type: AiDecisionQuestionType.noul,
          probability: requests,
        ),
        'needs_action': AiDecisionAnswer(
          type: AiDecisionQuestionType.noul,
          probability: needsAction,
        ),
        'bulk': AiDecisionAnswer(
          type: AiDecisionQuestionType.noul,
          probability: bulk,
        ),
        'due': AiDecisionAnswer(
          type: AiDecisionQuestionType.choice,
          choice: due,
        ),
        'urgency': AiDecisionAnswer(
          type: AiDecisionQuestionType.score,
          score: urgency,
        ),
      },
    );
  }

  /// Routes each decide call by the message's subject, so a test can script
  /// one answer per email.
  void stubDecide(Map<String, AiDecisionResponse> bySubject) {
    when(inference.decide(any)).thenAnswer((inv) async {
      final request = inv.positionalArguments.first as AiDecisionRequest;
      final state = request.state as Map<String, Object?>;
      final response = bySubject[state['subject']];
      if (response == null) {
        fail('unexpected decide for subject ${state['subject']}');
      }
      return Right(response);
    });
  }

  DetectCommitmentsParams params({
    List<Email> sent = const [],
    List<Email> inbox = const [],
    int maxToClassify = 30,
  }) {
    return DetectCommitmentsParams(
      accountId: account,
      selfAddresses: const {me},
      sentEmails: sent,
      inboxEmails: inbox,
      now: now,
      maxToClassify: maxToClassify,
    );
  }

  setUp(() {
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, Set<String>>>(const Right({}));
    provideDummy<Either<Failure, Unit>>(Right(unit));
    provideDummy<Either<Failure, List<Commitment>>>(const Right([]));
    provideDummy<Either<Failure, AiDecisionResponse>>(
      const Right(AiDecisionResponse(model: '', answers: {})),
    );

    settings = MockAiSettingsRepository();
    inference = MockAiInferenceRepository();
    ledger = MockCommitmentRepository();
    saved = [];

    when(settings.getRouting(AiCapability.triage)).thenAnswer(
      (_) async => const Right((providerId: 'jev', modelId: 'jev-latest')),
    );
    when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
        .thenAnswer((_) async => const Right(<String>{}));
    when(ledger.saveCommitments(any)).thenAnswer((inv) async {
      saved.addAll(inv.positionalArguments.first as List<Commitment>);
      return Right(unit);
    });
    when(ledger.markScanned(
      accountId: anyNamed('accountId'),
      emailIds: anyNamed('emailIds'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));
    when(ledger.getCommitments(accountId: anyNamed('accountId')))
        .thenAnswer((_) async => Right(List.of(saved)));
    when(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));

    detect = DetectCommitments(
      settingsRepository: settings,
      inferenceRepository: inference,
      commitmentRepository: ledger,
    );
  });

  group('routing', () {
    test('without a Triage route it fails closed and asks the model nothing',
        () async {
      when(settings.getRouting(AiCapability.triage))
          .thenAnswer((_) async => const Right(null));

      final result = await detect(params(
        sent: [email(id: 's1', from: me, to: ['a@x.com'], date: now)],
      ));

      result.fold(
        (f) {
          expect(f, isA<NoProviderConfigured>());
          expect(f.message, contains('Triage'));
        },
        (_) => fail('expected Left'),
      );
      verifyNever(inference.decide(any));
      verifyNever(ledger.markScanned(
        accountId: anyNamed('accountId'),
        emailIds: anyNamed('emailIds'),
        now: anyNamed('now'),
      ));
    });
  });

  group('sent mail', () {
    test('a promise becomes an "I owe" to the first outside recipient',
        () async {
      final sent = email(
        id: 's1',
        from: me,
        to: [me, 'sarah@client.com'],
        subject: 'Migration numbers',
        body: "Hi Sarah,\n\nI'll send the migration numbers today.\n\n"
            'On Tue, Sarah wrote:\n> can you send the numbers?',
        conversationId: 'conv-1',
        date: now.subtract(const Duration(hours: 2)),
      );
      stubDecide({
        'Migration numbers': answers(
          commits: 0.91,
          requests: 0.2,
          due: 'today',
          urgency: 1.6,
        ),
      });

      final result = await detect(params(sent: [sent]));

      final r = result.getOrElse((f) => fail('expected Right, got $f'));
      expect(r.classified, 1);
      expect(r.remaining, 0);
      expect(r.commitments, hasLength(1));
      final c = r.commitments.single;
      expect(c.id, 'iOwe:s1');
      expect(c.kind, CommitmentKind.iOwe);
      expect(c.status, CommitmentStatus.open);
      // The account holder's own address on the To line is skipped.
      expect(c.counterpart.address, 'sarah@client.com');
      expect(c.subject, 'Migration numbers');
      expect(c.due, CommitmentDue.today);
      expect(c.urgency, 2); // 1.6 rounds up
      expect(c.confidence, 0.91);
      expect(c.conversationId, 'conv-1');
      expect(c.emailDate, sent.sentDateTime);
      expect(c.detectedAt, now);

      // The model saw the newest reply only, as structured state.
      final request =
          verify(inference.decide(captureAny)).captured.single as AiDecisionRequest;
      expect(request.providerId, 'jev');
      expect(request.modelId, 'jev-latest');
      final state = request.state as Map<String, Object?>;
      expect(state['direction'], contains('sent'));
      expect(state['from'], contains(me));
      expect(state['to'], contains('sarah@client.com'));
      expect(state['body'], "Hi Sarah,\n\nI'll send the migration numbers today.");
      expect(request.questions.keys,
          containsAll(['commits', 'requests', 'due', 'urgency']));

      verify(ledger.markScanned(
        accountId: account,
        emailIds: argThat(equals(['s1']), named: 'emailIds'),
        now: now,
      )).called(1);
    });

    test('a request becomes a "they owe me"; both can come from one message',
        () async {
      final sent = email(
        id: 's2',
        from: me,
        to: ['peter@corp.com'],
        subject: 'Approval',
        body: 'I will draft the contract once you approve the budget.',
        date: now,
      );
      stubDecide({
        'Approval': answers(commits: 0.7, requests: 0.8, due: 'this_week'),
      });

      final r = (await detect(params(sent: [sent])))
          .getOrElse((f) => fail('$f'));

      expect(r.commitments.map((c) => c.id), ['iOwe:s2', 'theyOweMe:s2']);
      expect(r.commitments.every((c) => c.due == CommitmentDue.thisWeek), isTrue);
      expect(
        r.commitments.every((c) => c.counterpart.address == 'peter@corp.com'),
        isTrue,
      );
    });

    test('below threshold nothing is recorded, but the message is marked scanned',
        () async {
      final sent = email(
        id: 's3',
        from: me,
        to: ['a@x.com'],
        subject: 'Thanks',
        body: 'Thanks, got it.',
        date: now,
      );
      stubDecide({'Thanks': answers(commits: 0.3, requests: 0.1)});

      final r = (await detect(params(sent: [sent])))
          .getOrElse((f) => fail('$f'));

      expect(r.commitments, isEmpty);
      verifyNever(ledger.saveCommitments(any));
      verify(ledger.markScanned(
        accountId: account,
        emailIds: argThat(equals(['s3']), named: 'emailIds'),
        now: now,
      )).called(1);
    });
  });

  group('received mail', () {
    test('mail that needs action is recorded against its sender', () async {
      final inbox = email(
        id: 'i1',
        from: 'james@corp.com',
        to: [me],
        subject: 'Database access',
        preview: 'Could you reply about the database access request?',
        conversationId: 'conv-2',
        date: now.subtract(const Duration(days: 1)),
      );
      stubDecide({
        'Database access': answers(needsAction: 0.88, due: 'today', urgency: 1),
      });

      final r = (await detect(params(inbox: [inbox])))
          .getOrElse((f) => fail('$f'));

      final c = r.commitments.single;
      expect(c.id, 'needsAction:i1');
      expect(c.counterpart.address, 'james@corp.com');
      expect(c.due, CommitmentDue.today);
      // A day-old "today" is already overdue.
      expect(c.isOverdueAt(now), isTrue);
      // With no cached body the preview stands in.
      final state = verify(inference.decide(captureAny)).captured.single.state
          as Map<String, Object?>;
      expect(state['body'], inbox.bodyPreview);
      expect(state['direction'], contains('received'));
    });

    test('a sender\'s promise becomes a "they owe me"', () async {
      final inbox = email(
        id: 'i2',
        from: 'aws@support.com',
        to: [me],
        subject: 'Case 123',
        preview: 'We will get back to you within 2 business days.',
        date: now,
      );
      stubDecide({'Case 123': answers(commits: 0.75, needsAction: 0.1)});

      final r = (await detect(params(inbox: [inbox])))
          .getOrElse((f) => fail('$f'));

      expect(r.commitments.single.kind, CommitmentKind.theyOweMe);
      expect(r.commitments.single.counterpart.address, 'aws@support.com');
    });

    test('bulk mail vetoes every detection but still counts as scanned',
        () async {
      final inbox = email(
        id: 'i3',
        from: 'news@shop.com',
        to: [me],
        subject: 'Weekly deals',
        preview: 'Act now! Reply to claim your prize.',
        date: now,
      );
      stubDecide({
        'Weekly deals': answers(needsAction: 0.9, commits: 0.9, bulk: 0.95),
      });

      final r = (await detect(params(inbox: [inbox])))
          .getOrElse((f) => fail('$f'));

      expect(r.commitments, isEmpty);
      verify(ledger.markScanned(
        accountId: account,
        emailIds: argThat(equals(['i3']), named: 'emailIds'),
        now: now,
      )).called(1);
    });
  });

  group('candidate selection', () {
    test('skips messages already scanned and my own mail in the Inbox',
        () async {
      when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
          .thenAnswer((_) async => const Right({'s-old'}));
      final sentOld = email(
          id: 's-old', from: me, to: ['a@x.com'], subject: 'Old', date: now);
      final sentNew = email(
          id: 's-new', from: me, to: ['a@x.com'], subject: 'New', date: now);
      final inboxMine = email(
          id: 'i-mine', from: me, to: ['b@x.com'], subject: 'Mine', date: now);
      final inboxTheirs = email(
          id: 'i-theirs', from: 'b@x.com', to: [me], subject: 'Theirs', date: now);
      stubDecide({'New': answers(), 'Theirs': answers()});

      final r = (await detect(params(
        sent: [sentOld, sentNew],
        inbox: [inboxMine, inboxTheirs],
      )))
          .getOrElse((f) => fail('$f'));

      expect(r.classified, 2);
      final subjects = verify(inference.decide(captureAny))
          .captured
          .map((req) => (req.state as Map)['subject'])
          .toList();
      expect(subjects, unorderedEquals(['New', 'Theirs']));
    });

    test('newest first, capped, and reports what is left', () async {
      final emails = [
        for (var i = 0; i < 5; i++)
          email(
            id: 's$i',
            from: me,
            to: ['a@x.com'],
            subject: 'S$i',
            date: now.subtract(Duration(hours: i)),
          ),
      ];
      stubDecide({for (var i = 0; i < 5; i++) 'S$i': answers()});

      final r = (await detect(params(sent: emails, maxToClassify: 2)))
          .getOrElse((f) => fail('$f'));

      expect(r.classified, 2);
      expect(r.remaining, 3);
      final subjects = verify(inference.decide(captureAny))
          .captured
          .map((req) => (req.state as Map)['subject'])
          .toList();
      expect(subjects, ['S0', 'S1']);
    });
  });

  group('resolution', () {
    Commitment open({
      required CommitmentKind kind,
      required String emailId,
      required String counterpart,
      String? conversationId = 'conv',
      required DateTime emailDate,
    }) {
      return Commitment(
        id: Commitment.idFor(kind, emailId),
        accountId: account,
        emailId: emailId,
        conversationId: conversationId,
        kind: kind,
        status: CommitmentStatus.open,
        counterpart: EmailAddress(address: counterpart),
        subject: 's',
        snippet: '',
        due: CommitmentDue.none,
        urgency: 0,
        confidence: 0.9,
        emailDate: emailDate,
        detectedAt: emailDate,
      );
    }

    test('a counterpart reply in the thread closes a "they owe me"', () async {
      final asked = now.subtract(const Duration(days: 3));
      saved.add(open(
        kind: CommitmentKind.theyOweMe,
        emailId: 's1',
        counterpart: 'peter@corp.com',
        emailDate: asked,
      ));
      when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
          .thenAnswer((_) async => const Right({'s1', 'i1'}));
      final reply = email(
        id: 'i1',
        from: 'peter@corp.com',
        to: [me],
        conversationId: 'conv',
        date: now.subtract(const Duration(days: 1)),
      );

      final r = (await detect(params(inbox: [reply])))
          .getOrElse((f) => fail('$f'));

      expect(r.resolved, 1);
      expect(r.commitments.single.status, CommitmentStatus.done);
      expect(r.commitments.single.resolvedAt, now);
      verify(ledger.setStatus(
        accountId: account,
        id: 'theyOweMe:s1',
        status: CommitmentStatus.done,
        now: now,
      )).called(1);
    });

    test('my own later reply in the thread closes a "needs action"', () async {
      final received = now.subtract(const Duration(days: 2));
      saved.add(open(
        kind: CommitmentKind.needsAction,
        emailId: 'i1',
        counterpart: 'james@corp.com',
        emailDate: received,
      ));
      when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
          .thenAnswer((_) async => const Right({'i1', 's9'}));
      final myReply = email(
        id: 's9',
        from: me,
        to: ['james@corp.com'],
        conversationId: 'conv',
        date: now.subtract(const Duration(days: 1)),
      );

      final r = (await detect(params(sent: [myReply])))
          .getOrElse((f) => fail('$f'));

      expect(r.resolved, 1);
      expect(r.commitments.single.status, CommitmentStatus.done);
    });

    test('an "I owe" is never closed by mail alone, and threads must match',
        () async {
      final promised = now.subtract(const Duration(days: 2));
      saved.add(open(
        kind: CommitmentKind.iOwe,
        emailId: 's1',
        counterpart: 'sarah@client.com',
        emailDate: promised,
      ));
      saved.add(open(
        kind: CommitmentKind.theyOweMe,
        emailId: 's2',
        counterpart: 'peter@corp.com',
        conversationId: 'other-thread',
        emailDate: promised,
      ));
      when(ledger.getScannedEmailIds(accountId: anyNamed('accountId')))
          .thenAnswer((_) async => const Right({'s1', 's2', 's3', 'i1'}));
      final mySecond = email(
        id: 's3',
        from: me,
        to: ['sarah@client.com'],
        conversationId: 'conv',
        date: now,
      );
      final peterElsewhere = email(
        id: 'i1',
        from: 'peter@corp.com',
        to: [me],
        conversationId: 'conv', // not the thread the request was made in
        date: now,
      );

      final r = (await detect(params(sent: [mySecond], inbox: [peterElsewhere])))
          .getOrElse((f) => fail('$f'));

      expect(r.resolved, 0);
      expect(r.commitments.every((c) => c.isOpen), isTrue);
      verifyNever(ledger.setStatus(
        accountId: anyNamed('accountId'),
        id: anyNamed('id'),
        status: anyNamed('status'),
        now: anyNamed('now'),
      ));
    });
  });

  group('provider failures', () {
    test('a failure on the first message is the result', () async {
      when(inference.decide(any)).thenAnswer(
        (_) async => const Left(ProviderUnreachable(message: 'down')),
      );

      final result = await detect(params(
        sent: [email(id: 's1', from: me, to: ['a@x.com'], date: now)],
      ));

      result.fold(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
      verifyNever(ledger.markScanned(
        accountId: anyNamed('accountId'),
        emailIds: anyNamed('emailIds'),
        now: anyNamed('now'),
      ));
    });

    test('a failure part-way keeps what was classified and warns', () async {
      final first = email(
          id: 's1', from: me, to: ['a@x.com'], subject: 'First', date: now);
      final second = email(
          id: 's2',
          from: me,
          to: ['a@x.com'],
          subject: 'Second',
          date: now.subtract(const Duration(hours: 1)));
      var calls = 0;
      when(inference.decide(any)).thenAnswer((_) async {
        calls++;
        if (calls == 1) return Right(answers(commits: 0.9));
        return const Left(RateLimited(message: 'slow down'));
      });

      final r = (await detect(params(sent: [first, second])))
          .getOrElse((f) => fail('$f'));

      expect(r.classified, 1);
      expect(r.remaining, 1);
      expect(r.warning, 'slow down');
      expect(r.commitments.single.id, 'iOwe:s1');
      verify(ledger.markScanned(
        accountId: account,
        emailIds: argThat(equals(['s1']), named: 'emailIds'),
        now: now,
      )).called(1);
    });
  });

  group('bodyExcerpt', () {
    test('cuts quoted history, collapses spaces and caps the length', () {
      final long = 'word ' * 1000;
      final e = email(
        id: 'x',
        from: me,
        body: '$long\n\nOn Mon, someone wrote:\n> old stuff',
        date: now,
      );
      final excerpt = DetectCommitments.bodyExcerpt(e);
      expect(excerpt.length, DetectCommitments.maxBodyChars);
      expect(excerpt, isNot(contains('old stuff')));
    });
  });
}
