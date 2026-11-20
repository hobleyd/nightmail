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
import 'package:nightmail/domain/entities/ai/compose_draft_snapshot.dart';
import 'package:nightmail/domain/repositories/ai/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/domain/usecases/ai/agent/agent_loop.dart';
import 'package:nightmail/domain/usecases/ai/agent/compose_agent_tools.dart';
import 'package:nightmail/domain/usecases/ai/run_compose_assistant.dart';

import 'run_compose_assistant_test.mocks.dart';

@GenerateMocks([
  AiInferenceRepository,
  AiSettingsRepository,
  AiCatalogRepository,
])
void main() {
  late RunComposeAssistant useCase;
  late MockAiInferenceRepository mockInference;
  late MockAiSettingsRepository mockSettings;
  late MockAiCatalogRepository mockCatalog;
  late List<Stream<Either<Failure, AiChunk>>> scriptedRounds;

  const tRouting = (providerId: 'openai', modelId: 'gpt-4o');

  const snapshot = ComposeDraftSnapshot(
    draft: 'Hi Bob,\nyes please.',
    subject: 'Re: Lunch',
    to: ['Bob <bob@example.com>'],
    isReply: true,
    signatureSeparated: true,
    originalMessage: 'QUOTED-ORIGINAL: shall we have lunch?',
  );

  AiProvider provider(AiProviderKind kind) => AiProvider(
        id: 'openai',
        name: 'OpenAI',
        npm: '@ai-sdk/openai',
        doc: 'https://example.com/docs',
        env: const ['OPENAI_API_KEY'],
        kind: kind,
        wireProtocol: AiWireProtocol.openai,
        source: AiProviderSource.catalog,
      );

  AiModel model({required bool toolCall}) => AiModel(
        id: 'gpt-4o',
        providerId: 'openai',
        name: 'GPT-4o',
        attachment: false,
        reasoning: false,
        toolCall: toolCall,
        openWeights: false,
        releaseDate: '2024-01-01',
        lastUpdated: '2024-01-01',
        inputModalities: const ['text'],
        outputModalities: const ['text'],
        contextLimit: 128000,
        outputLimit: 4096,
      );

  Stream<Either<Failure, AiChunk>> toolCallRound(List<AiToolCall> calls) =>
      Stream.fromIterable([
        Right(AiChunk(
          delta: '',
          done: true,
          finishReason: 'tool_calls',
          toolCalls: calls,
        )),
      ]);

  Stream<Either<Failure, AiChunk>> textRound(String text) =>
      Stream.fromIterable([
        Right(AiChunk(delta: text, done: true, finishReason: 'stop')),
      ]);

  List<AiRequest> capturedRequests() =>
      verify(mockInference.stream(captureAny)).captured.cast<AiRequest>();

  setUp(() {
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, bool>>(const Right(false));
    provideDummy<Either<Failure, int>>(const Right(0));
    provideDummy<Either<Failure, AiProvider>>(
      Right(provider(AiProviderKind.cloud)),
    );
    provideDummy<Either<Failure, AiModel>>(Right(model(toolCall: true)));
    provideDummy<Stream<Either<Failure, AiChunk>>>(
      const Stream<Either<Failure, AiChunk>>.empty(),
    );

    mockInference = MockAiInferenceRepository();
    mockSettings = MockAiSettingsRepository();
    mockCatalog = MockAiCatalogRepository();
    useCase = RunComposeAssistant(
      settingsRepository: mockSettings,
      inferenceRepository: mockInference,
      catalogRepository: mockCatalog,
    );

    when(mockSettings.getRouting(AiCapability.compose))
        .thenAnswer((_) async => const Right(tRouting));
    when(mockSettings.getAllowCloudForBodies())
        .thenAnswer((_) async => const Right(false));
    when(mockCatalog.getProvider('openai'))
        .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
    when(mockCatalog.getModel(
      providerId: anyNamed('providerId'),
      modelId: anyNamed('modelId'),
    )).thenAnswer((_) async => Right(model(toolCall: true)));

    scriptedRounds = [];
    when(mockInference.stream(any)).thenAnswer((_) => scriptedRounds.isNotEmpty
        ? scriptedRounds.removeAt(0)
        : const Stream<Either<Failure, AiChunk>>.empty());
  });

  group('RunComposeAssistant', () {
    test(
        'carries the draft in the system prompt, offers only propose_draft, '
        'and keeps history to what was said', () async {
      scriptedRounds.add(textRound('Looks good.'));
      const history = [
        AiMessage(role: AiRole.user, content: 'earlier question'),
        AiMessage(role: AiRole.assistant, content: 'earlier answer'),
      ];

      await useCase(
        history: history,
        userInstruction: 'Review it',
        snapshot: snapshot,
      ).toList();

      final request = capturedRequests().single;
      expect(request.tools!.map((t) => t.name), [ProposeDraftTool.toolName]);
      expect(request.messages.first.role, AiRole.system);
      expect(request.messages.first.content, contains('Hi Bob,\nyes please.'));
      expect(request.messages.first.content, contains('Subject: Re: Lunch'));
      expect(request.messages.first.content,
          contains('To: Bob <bob@example.com>'));
      expect(request.messages.skip(1).map((m) => m.content), [
        'earlier question',
        'earlier answer',
        'Review it',
      ]);
    });

    test(
        'a proposal runs through the loop as a no-op tool whose result tells '
        'the model it was not applied', () async {
      scriptedRounds
        ..add(toolCallRound(const [
          AiToolCall(
            id: 'c1',
            name: ProposeDraftTool.toolName,
            arguments: {'text': 'Hi Bob,\n\nYes, lunch on Friday works.'},
          ),
        ]))
        ..add(textRound('I made it warmer.'));

      final emitted = await useCase(
        history: const [],
        userInstruction: 'Make it warmer',
        snapshot: snapshot,
      ).toList();

      final chunks = emitted.map((e) => e.getRight().toNullable()!).toList();
      final started = chunks.firstWhere(
          (c) => c.finishReason == AgentLoop.toolActivityFinishReason);
      expect(started.toolCalls!.single.arguments['text'],
          'Hi Bob,\n\nYes, lunch on Friday works.');
      final result = chunks
          .firstWhere(
              (c) => c.finishReason == AgentLoop.toolResultFinishReason)
          .toolResult!;
      expect(result.isError, isFalse);
      expect(jsonDecode(result.output)['status'], 'put_in_message');
      expect(chunks.last.delta, 'I made it warmer.');
    });

    test('withholds the quoted message from a cloud provider without opt-in',
        () async {
      scriptedRounds.add(textRound('ok'));
      await useCase(
        history: const [],
        userInstruction: 'Draft a reply',
        snapshot: snapshot,
      ).toList();

      final system = capturedRequests().single.messages.first.content;
      expect(system, isNot(contains('QUOTED-ORIGINAL')));
      expect(system, contains('not shown to you'));
      // The user's own writing is what they asked about, so it always goes.
      expect(system, contains('yes please.'));
    });

    test('includes the quoted message for a local provider', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.local)));
      scriptedRounds.add(textRound('ok'));
      await useCase(
        history: const [],
        userInstruction: 'Draft a reply',
        snapshot: snapshot,
      ).toList();

      final system = capturedRequests().single.messages.first.content;
      expect(system, contains('QUOTED-ORIGINAL'));
      expect(system, contains('background only'));
    });

    test('includes the quoted message for a cloud provider once opted in',
        () async {
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(true));
      scriptedRounds.add(textRound('ok'));
      await useCase(
        history: const [],
        userInstruction: 'Draft a reply',
        snapshot: snapshot,
      ).toList();

      expect(capturedRequests().single.messages.first.content,
          contains('QUOTED-ORIGINAL'));
    });

    test('falls back to plain chat when the cloud model cannot call tools',
        () async {
      when(mockCatalog.getModel(
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      )).thenAnswer((_) async => Right(model(toolCall: false)));
      scriptedRounds.add(textRound('Here is a version…'));

      await useCase(
        history: const [],
        userInstruction: 'Rewrite it',
        snapshot: snapshot,
      ).toList();

      final request = capturedRequests().single;
      expect(request.tools, anyOf(isNull, isEmpty));
      expect(request.messages.first.content,
          contains('You cannot change the draft yourself'));
      expect(request.messages.last.content, 'Rewrite it');
    });

    test('no routed provider is a single NoProviderConfigured', () async {
      when(mockSettings.getRouting(AiCapability.compose))
          .thenAnswer((_) async => const Right(null));

      final emitted = await useCase(
        history: const [],
        userInstruction: 'hi',
        snapshot: snapshot,
      ).toList();

      expect(emitted.single.getLeft().toNullable(),
          isA<NoProviderConfigured>());
      verifyNever(mockInference.stream(any));
    });
  });

  group('RunComposeAssistant.buildSystemPrompt', () {
    test('an empty draft is said to be empty', () {
      final prompt = RunComposeAssistant.buildSystemPrompt(
        const ComposeDraftSnapshot(draft: '  '),
        includeOriginal: true,
        toolCapable: true,
      );
      expect(prompt, contains('(empty'));
      expect(prompt, contains('a new message'));
      expect(prompt, isNot(contains('<<<DRAFT')));
    });

    test('the signature rule follows whether it was taken out of the draft',
        () {
      String prompt(bool separated) => RunComposeAssistant.buildSystemPrompt(
            ComposeDraftSnapshot(draft: 'x', signatureSeparated: separated),
            includeOriginal: true,
            toolCapable: true,
          );
      expect(prompt(true), contains('kept automatically'));
      expect(prompt(false), contains('keep it unchanged'));
    });

    test('a long quoted message is clipped', () {
      final prompt = RunComposeAssistant.buildSystemPrompt(
        ComposeDraftSnapshot(
          draft: 'x',
          isReply: true,
          originalMessage: 'a' * (RunComposeAssistant.maxOriginalChars + 500),
        ),
        includeOriginal: true,
        toolCapable: true,
      );
      expect(prompt, contains('[…truncated]'));
      expect(prompt.length,
          lessThan(RunComposeAssistant.maxOriginalChars + 4000));
    });
  });

  group('ProposeDraftTool', () {
    test('a proposal with no text is an error the model can read', () async {
      final result = await const ProposeDraftTool().invoke({'text': ' '});
      expect(jsonDecode(result.getRight().toNullable()!)['error'], isNotNull);
    });
  });
}
