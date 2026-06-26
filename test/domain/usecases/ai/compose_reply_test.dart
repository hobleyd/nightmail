import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/repositories/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai_settings_repository.dart';
import 'package:nightmail/domain/usecases/ai/compose_reply.dart';

import 'compose_reply_test.mocks.dart';

@GenerateMocks([
  AiInferenceRepository,
  AiSettingsRepository,
  AiCatalogRepository,
])
void main() {
  late ComposeReply useCase;
  late MockAiSettingsRepository mockSettings;
  late MockAiInferenceRepository mockInference;
  late MockAiCatalogRepository mockCatalog;

  const tRouting = (providerId: 'openai', modelId: 'gpt-4o');
  const tOriginalBody = 'Are you coming to the meeting?';

  /// Builds a provider descriptor of the requested privacy [kind]. Only `kind`
  /// is load-bearing for the cloud-bodies guard; the rest are filler.
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

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types like
    // Either, so we register them explicitly.
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, String?>>(const Right(null));
    provideDummy<Either<Failure, bool>>(const Right(false));
    provideDummy<Either<Failure, AiProvider>>(
      Right(provider(AiProviderKind.cloud)),
    );

    mockSettings = MockAiSettingsRepository();
    mockInference = MockAiInferenceRepository();
    mockCatalog = MockAiCatalogRepository();
    useCase = ComposeReply(
      settingsRepository: mockSettings,
      inferenceRepository: mockInference,
      catalogRepository: mockCatalog,
    );

    // Sensible defaults; individual tests override what they care about.
    when(mockSettings.getRouting(AiCapability.compose))
        .thenAnswer((_) async => const Right(tRouting));
    when(mockSettings.getAllowCloudForBodies())
        .thenAnswer((_) async => const Right(false));
    when(mockCatalog.getProvider('openai'))
        .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
    when(mockInference.stream(any)).thenAnswer(
      (_) => Stream<Either<Failure, AiChunk>>.fromIterable(
        const [Right(AiChunk(delta: 'ok', done: true, finishReason: 'stop'))],
      ),
    );
  });

  /// Drains the use case and returns the request handed to the inference layer.
  Future<AiRequest> captureRequest({
    String instruction = 'Reply saying I will attend.',
    String? originalMessage = tOriginalBody,
  }) async {
    await useCase
        .call(instruction: instruction, originalMessage: originalMessage)
        .toList();
    return verify(mockInference.stream(captureAny)).captured.single
        as AiRequest;
  }

  /// The user-turn content carrying the instruction (and possibly the body).
  String userTurnOf(AiRequest request) =>
      request.messages.lastWhere((m) => m.role == AiRole.user).content;

  group('ComposeReply', () {
    test(
        'happy path: builds a streaming request from routing and forwards the '
        'inference stream', () async {
      const chunks = [
        AiChunk(delta: 'Hi '),
        AiChunk(delta: 'there', done: true, finishReason: 'stop'),
      ];
      when(mockInference.stream(any)).thenAnswer(
        (_) => Stream.fromIterable(
          chunks.map<Either<Failure, AiChunk>>(Right.new),
        ),
      );

      final emitted = await useCase
          .call(
            instruction: 'Reply saying I will attend.',
            originalMessage: tOriginalBody,
          )
          .toList();

      // The emitted chunk stream is passed straight through.
      expect(emitted, [Right(chunks[0]), Right(chunks[1])]);

      // Capture and inspect the request handed to the inference repository.
      final captured =
          verify(mockInference.stream(captureAny)).captured.single as AiRequest;
      expect(captured.providerId, 'openai');
      expect(captured.modelId, 'gpt-4o');
      expect(captured.stream, isTrue);

      // System prompt + a user turn carrying the instruction.
      expect(captured.messages.first.role, AiRole.system);
      expect(captured.messages.first.content, isNotEmpty);
      expect(userTurnOf(captured), contains('Reply saying I will attend.'));

      verify(mockSettings.getRouting(AiCapability.compose)).called(1);
      // Auth is the inference layer's job — ComposeReply must NOT gate on a key.
      verifyNever(mockSettings.getApiKey(any));
    });

    // --- Privacy "cloud bodies" guard (H1 / M5) ---------------------------

    test(
        'cloud provider + allowCloudForBodies=false: the quoted original body '
        'is withheld (instruction only)', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));

      final request = await captureRequest();

      // The model still receives the instruction, just without the body.
      expect(userTurnOf(request), contains('Reply saying I will attend.'));
      expect(userTurnOf(request), isNot(contains(tOriginalBody)));
      expect(userTurnOf(request), isNot(contains('Message being replied to')));
    });

    test(
        'cloud provider + allowCloudForBodies=true: the original body IS '
        'included as context', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.cloud)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(true));

      final request = await captureRequest();

      expect(userTurnOf(request), contains('Reply saying I will attend.'));
      expect(userTurnOf(request), contains(tOriginalBody));
    });

    test(
        'local provider: the original body is included regardless of the '
        'cloud flag (which stays at its safe default)', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.local)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));

      final request = await captureRequest();

      expect(userTurnOf(request), contains(tOriginalBody));
    });

    test(
        'self-hosted provider: the original body is included regardless of the '
        'cloud flag', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.selfHosted)));
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));

      final request = await captureRequest();

      expect(userTurnOf(request), contains(tOriginalBody));
    });

    test(
        'fails safe: when the provider cannot be resolved it is treated as '
        'cloud and the body is withheld at the safe default', () async {
      when(mockCatalog.getProvider('openai')).thenAnswer(
        (_) async => const Left(NoProviderConfigured(message: 'unknown')),
      );
      when(mockSettings.getAllowCloudForBodies())
          .thenAnswer((_) async => const Right(false));

      final request = await captureRequest();

      expect(userTurnOf(request), isNot(contains(tOriginalBody)));
    });

    // --- Auth / routing behaviour ----------------------------------------

    test(
        'does not gate on an API key — forwards to inference even when the '
        'provider has no key stored (e.g. local Ollama)', () async {
      when(mockCatalog.getProvider('openai'))
          .thenAnswer((_) async => Right(provider(AiProviderKind.local)));
      when(mockSettings.getApiKey('openai'))
          .thenAnswer((_) async => const Right(null));

      final emitted =
          await useCase.call(instruction: 'Draft a reply.').toList();

      expect(emitted, hasLength(1));
      expect(emitted.single.isRight(), isTrue);
      verify(mockInference.stream(any)).called(1);
      verifyNever(mockSettings.getApiKey(any));
    });

    test(
        'no routing configured: emits a single Left(NoProviderConfigured) and '
        'never calls inference.stream()', () async {
      when(mockSettings.getRouting(AiCapability.compose))
          .thenAnswer((_) async => const Right(null));

      final emitted =
          await useCase.call(instruction: 'Draft a reply.').toList();

      expect(emitted, hasLength(1));
      expect(emitted.single.isLeft(), isTrue);
      expect(
        emitted.single.getLeft().toNullable(),
        isA<NoProviderConfigured>(),
      );

      verifyNever(mockInference.stream(any));
      verifyNever(mockSettings.getApiKey(any));
    });

    test(
        'routing lookup failure: emits the source Left and never calls '
        'inference.stream()', () async {
      const failure = CacheFailure(message: 'db read failed');
      when(mockSettings.getRouting(AiCapability.compose))
          .thenAnswer((_) async => const Left(failure));

      final emitted =
          await useCase.call(instruction: 'Draft a reply.').toList();

      expect(emitted, [const Left<Failure, AiChunk>(failure)]);
      verifyNever(mockInference.stream(any));
    });
  });
}
