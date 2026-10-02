import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/repositories/ai/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/domain/repositories/commitment_repository.dart';
import 'package:nightmail/domain/usecases/commitments/agent/commitment_agent_tools.dart';
import 'package:nightmail/domain/usecases/commitments/run_commitments_agent.dart';
import 'package:nightmail/domain/usecases/commitments/schedule_commitment.dart';
import 'package:nightmail/domain/usecases/commitments/suggest_time_block.dart';

import 'run_commitments_agent_test.mocks.dart';

@GenerateMocks([
  AiSettingsRepository,
  AiInferenceRepository,
  AiCatalogRepository,
  ScheduleCommitment,
  CommitmentRepository,
])
void main() {
  late MockAiSettingsRepository settings;
  late MockAiInferenceRepository inference;
  late MockAiCatalogRepository catalog;
  late MockScheduleCommitment scheduler;
  late MockCommitmentRepository ledger;
  late RunCommitmentsAgent agent;

  // Tuesday 6 October 2026, 09:00.
  final now = DateTime(2026, 10, 6, 9);

  Commitment commitment(String id, CommitmentKind kind, String who, String subject) =>
      Commitment(
        id: Commitment.idFor(kind, id),
        accountId: 'acc',
        emailId: id,
        kind: kind,
        status: CommitmentStatus.open,
        counterpart: EmailAddress(address: '$who@example.com', name: who),
        subject: subject,
        snippet: subject,
        due: CommitmentDue.thisWeek,
        urgency: 1,
        confidence: 0.9,
        emailDate: now,
        detectedAt: now,
      );

  final sarah = commitment('s1', CommitmentKind.iOwe, 'Sarah', 'Migration numbers');
  final james = commitment('i1', CommitmentKind.needsAction, 'James', 'Database access');

  final snapshot = CommitmentsAgentSnapshot(
    accountId: 'acc',
    commitments: [sarah, james],
    events: const [],
    taskDueDates: const [],
    now: now,
  );

  const cloud = AiProvider(
    id: 'openai',
    name: 'OpenAI',
    npm: '@ai-sdk/openai',
    doc: '',
    env: ['OPENAI_API_KEY'],
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.openai,
    source: AiProviderSource.catalog,
  );

  AiModel model({required bool toolCall}) => AiModel(
        id: 'gpt',
        providerId: 'openai',
        name: 'GPT',
        attachment: false,
        reasoning: false,
        toolCall: toolCall,
        openWeights: false,
        releaseDate: '',
        lastUpdated: '',
        inputModalities: const ['text'],
        outputModalities: const ['text'],
        contextLimit: 128000,
        outputLimit: 8192,
      );

  /// A model round that ends in tool calls.
  Stream<Either<Failure, AiChunk>> toolRound(List<AiToolCall> calls) =>
      Stream.fromIterable([
        Right(AiChunk(
          delta: '',
          done: true,
          finishReason: 'tool_calls',
          toolCalls: calls,
        )),
      ]);

  /// A model round that answers in text.
  Stream<Either<Failure, AiChunk>> textRound(String text) =>
      Stream.fromIterable([
        Right(AiChunk(delta: text)),
        const Right(AiChunk(delta: '', done: true, finishReason: 'stop')),
      ]);

  setUp(() {
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, int>>(const Right(0));
    provideDummy<Either<Failure, AiProvider>>(const Right(cloud));
    provideDummy<Either<Failure, AiModel>>(Right(model(toolCall: true)));
    provideDummy<Either<Failure, Commitment>>(Right(sarah));
    provideDummy<Either<Failure, Unit>>(Right(unit));

    settings = MockAiSettingsRepository();
    inference = MockAiInferenceRepository();
    catalog = MockAiCatalogRepository();
    scheduler = MockScheduleCommitment();
    ledger = MockCommitmentRepository();

    when(settings.getRouting(AiCapability.compose)).thenAnswer(
      (_) async => const Right((providerId: 'openai', modelId: 'gpt')),
    );
    when(settings.getAgentMaxRounds()).thenAnswer((_) async => const Right(5));
    when(settings.getAgentMaxToolCallsPerRound())
        .thenAnswer((_) async => const Right(8));
    when(catalog.getProvider('openai')).thenAnswer((_) async => const Right(cloud));
    when(catalog.getModel(providerId: 'openai', modelId: 'gpt'))
        .thenAnswer((_) async => Right(model(toolCall: true)));
    when(scheduler.call(any, start: anyNamed('start'), end: anyNamed('end')))
        .thenAnswer((inv) async {
      final c = inv.positionalArguments.first as Commitment;
      final start = inv.namedArguments[#start] as DateTime;
      final end = inv.namedArguments[#end] as DateTime;
      return Right(c.copyWith(
        scheduledEventId: 'ev-${c.emailId}',
        scheduledStart: start,
        scheduledEnd: end,
      ));
    });
    when(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    )).thenAnswer((_) async => Right(unit));

    agent = RunCommitmentsAgent(
      settingsRepository: settings,
      inferenceRepository: inference,
      catalogRepository: catalog,
      scheduleCommitment: scheduler,
      commitmentRepository: ledger,
    );
  });

  Future<List<AiChunk>> run(String instruction) async {
    final events = await agent
        .call(history: const [], userInstruction: instruction, snapshot: snapshot)
        .toList();
    return [
      for (final e in events)
        e.fold((f) => throw StateError('unexpected failure $f'), (c) => c),
    ];
  }

  test('advertises the ledger tools and turns an instruction into tool calls',
      () async {
    var round = 0;
    when(inference.stream(any)).thenAnswer((_) {
      round++;
      switch (round) {
        case 1:
          return toolRound([
            const AiToolCall(id: 'c1', name: 'list_commitments', arguments: {}),
          ]);
        case 2:
          return toolRound([
            AiToolCall(id: 'c2', name: 'schedule_block', arguments: {
              'commitment_id': sarah.id,
              'start': '2026-10-08T14:00',
              'duration_minutes': 120,
            }),
          ]);
        default:
          return textRound('Blocked two hours for the migration numbers on Thursday at 2 PM.');
      }
    });

    final chunks = await run('Give me 2 hours on Thursday for the migration numbers');

    // The first request carried the tool set and the clock-bearing prompt.
    final first = verify(inference.stream(captureAny)).captured.first as AiRequest;
    expect(
      first.tools!.map((t) => t.name),
      ['list_commitments', 'get_forecast', 'find_free_slot', 'suggest_block',
        'schedule_block', 'mark_done', 'dismiss'],
    );
    expect(first.messages.first.role, AiRole.system);
    expect(first.messages.first.content, contains('Tuesday 2026-10-06 09:00'));
    expect(first.messages.first.content, contains('9:00–17:00'));

    // The listing handed the model real ids…
    final listResult = chunks
        .firstWhere((c) => c.toolResult?.callId == 'c1')
        .toolResult!;
    expect(listResult.isError, isFalse);
    final listed = jsonDecode(listResult.output) as Map<String, dynamic>;
    expect(listed['count'], 2);
    expect((listed['commitments'] as List).map((c) => c['id']),
        containsAll([sarah.id, james.id]));

    // …and the booking went through the scheduler at the asked time.
    verify(scheduler.call(
      sarah,
      start: DateTime(2026, 10, 8, 14),
      end: DateTime(2026, 10, 8, 16),
    )).called(1);
    final bookResult = chunks
        .firstWhere((c) => c.toolResult?.callId == 'c2')
        .toolResult!;
    final booked = jsonDecode(bookResult.output) as Map<String, dynamic>;
    expect(booked['ok'], isTrue);
    expect(booked['moved'], isFalse);
    expect(booked['calendar_subject'], 'Migration numbers — for Sarah');

    // Activity labels for the cards, and the final text.
    expect(
      chunks
          .where((c) => c.finishReason == RunCommitmentsAgent.toolActivityFinishReason)
          .map((c) => c.delta),
      ['Reading the ledger…', 'Blocking time…'],
    );
    expect(chunks.map((c) => c.delta).join(), contains('Blocked two hours'));
  });

  test('mark_done closes a commitment through the ledger', () async {
    var round = 0;
    when(inference.stream(any)).thenAnswer((_) {
      round++;
      return round == 1
          ? toolRound([
              AiToolCall(id: 'c1', name: 'mark_done', arguments: {
                'commitment_id': james.id,
              }),
            ])
          : textRound('Marked the database access reply done.');
    });

    await run('The database access thing is handled');

    verify(ledger.setStatus(
      accountId: 'acc',
      id: james.id,
      status: CommitmentStatus.done,
      now: now,
    )).called(1);
  });

  test('an unknown id is answered with an error the model can recover from',
      () async {
    var round = 0;
    when(inference.stream(any)).thenAnswer((_) {
      round++;
      return round == 1
          ? toolRound([
              const AiToolCall(id: 'c1', name: 'dismiss', arguments: {
                'commitment_id': 'iOwe:nope',
              }),
            ])
          : textRound('I could not find that one.');
    });

    final chunks = await run('Dismiss the thing');

    final result = chunks.firstWhere((c) => c.toolResult != null).toolResult!;
    expect(result.isError, isFalse); // a recoverable input problem, not a Left
    expect(result.output, contains('No open commitment with id'));
    verifyNever(ledger.setStatus(
      accountId: anyNamed('accountId'),
      id: anyNamed('id'),
      status: anyNamed('status'),
      now: anyNamed('now'),
    ));
  });

  test('without a Compose route it says what to set up', () async {
    when(settings.getRouting(AiCapability.compose))
        .thenAnswer((_) async => const Right(null));

    final events = await agent
        .call(history: const [], userInstruction: 'x', snapshot: snapshot)
        .toList();

    expect(events, hasLength(1));
    events.single.fold(
      (f) {
        expect(f, isA<NoProviderConfigured>());
        expect(f.message, contains('Compose'));
      },
      (_) => fail('expected Left'),
    );
    verifyNever(inference.stream(any));
  });

  test('a cloud model that cannot call tools fails closed', () async {
    when(catalog.getModel(providerId: 'openai', modelId: 'gpt'))
        .thenAnswer((_) async => Right(model(toolCall: false)));

    final events = await agent
        .call(history: const [], userInstruction: 'x', snapshot: snapshot)
        .toList();

    events.single.fold(
      (f) => expect(f, isA<UnsupportedFailure>()),
      (_) => fail('expected Left'),
    );
    verifyNever(inference.stream(any));
  });

  test('the prompt names the clock and the working window', () {
    final prompt = RunCommitmentsAgent.systemPromptFor(now, const SuggestTimeBlock());
    expect(prompt, contains('Tuesday 2026-10-06 09:00'));
    expect(prompt, contains('9:00–17:00'));
    expect(prompt, contains('list_commitments first'));
    expect(prompt, contains('Never move an item past its due day'));
  });
}
