import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/ai_adapter_factory.dart';
import 'package:nightmail/data/datasources/ai/ai_provider_registry.dart';
import 'package:nightmail/data/datasources/ai/inference/ai_adapter.dart';
import 'package:nightmail/data/repositories/ai/ai_inference_repository_impl.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';

import 'ai_inference_repository_impl_test.mocks.dart';

@GenerateMocks([
  AiProviderRegistry,
  AiAdapterFactory,
  AiSettingsRepository,
  AiAdapter,
])
void main() {
  late AiInferenceRepositoryImpl repository;
  late MockAiProviderRegistry mockRegistry;
  late MockAiAdapterFactory mockAdapterFactory;
  late MockAiSettingsRepository mockSettingsRepository;
  late MockAiAdapter mockAdapter;

  // A provider that requires an API key and declares an explicit base URL, so we
  // can assert the exact endpoint passed down to the adapter.
  const tProvider = AiProvider(
    id: 'openai',
    name: 'OpenAI',
    npm: '@ai-sdk/openai',
    doc: 'https://example.com',
    env: ['OPENAI_API_KEY'],
    apiBaseUrl: 'https://api.example.com/v1',
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.openai,
    source: AiProviderSource.catalog,
  );

  // A user/BYO provider that nominally declares a key requirement but, being
  // user-managed (e.g. local Ollama), must NOT be pre-empted when no key exists.
  const tByoProvider = AiProvider(
    id: 'byo_ollama',
    name: 'Ollama',
    npm: '',
    doc: '',
    env: ['API_KEY'],
    apiBaseUrl: 'http://localhost:11434/v1',
    kind: AiProviderKind.local,
    wireProtocol: AiWireProtocol.openai,
    source: AiProviderSource.user,
  );

  // A first-party Anthropic catalog provider with NO explicit apiBaseUrl, so the
  // inference repo must supply its default. The default must be exactly
  // `https://api.anthropic.com` (no trailing `/v1`) so the Anthropic adapter,
  // which appends `/v1/messages`, forms `.../v1/messages` once — not the
  // doubled `/v1/v1/messages` that 404s (finding H2).
  const tAnthropicProvider = AiProvider(
    id: 'anthropic',
    name: 'Anthropic',
    npm: '@ai-sdk/anthropic',
    doc: 'https://example.com',
    env: ['ANTHROPIC_API_KEY'],
    apiBaseUrl: null,
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.anthropic,
    source: AiProviderSource.catalog,
  );

  // An Azure provider with NO apiBaseUrl. Azure has no fixed endpoint, so this
  // must fail closed with NoProviderConfigured rather than dialing a placeholder
  // host (finding L14).
  const tAzureProvider = AiProvider(
    id: 'azure',
    name: 'Azure OpenAI',
    npm: '@ai-sdk/azure',
    doc: 'https://example.com',
    env: ['AZURE_API_KEY'],
    apiBaseUrl: null,
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.azure,
    source: AiProviderSource.catalog,
  );

  // Builds a minimal model fixture; only `id` and `providerOverride` matter for
  // the shape-resolution tests, the rest are filled with neutral defaults.
  AiModel buildModel({
    required String id,
    required String providerId,
    Map<String, Object?>? providerOverride,
  }) {
    return AiModel(
      id: id,
      providerId: providerId,
      name: id,
      attachment: false,
      reasoning: false,
      toolCall: false,
      openWeights: false,
      releaseDate: '2026-01-01',
      lastUpdated: '2026-01-01',
      inputModalities: const ['text'],
      outputModalities: const ['text'],
      contextLimit: 128000,
      outputLimit: 8192,
      providerOverride: providerOverride,
    );
  }

  // An OpenAI-protocol provider whose selected model declares the Responses wire
  // shape via its catalog `providerOverride` ({shape: 'responses'}). Routing to
  // this model must hand the adapter a request with shape == responses.
  final tResponsesProvider = AiProvider(
    id: 'openai',
    name: 'OpenAI',
    npm: '@ai-sdk/openai',
    doc: 'https://example.com',
    env: const ['OPENAI_API_KEY'],
    apiBaseUrl: 'https://api.example.com/v1',
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.openai,
    source: AiProviderSource.catalog,
    models: [
      buildModel(
        id: 'gpt-5-responses',
        providerId: 'openai',
        providerOverride: const {'shape': 'responses'},
      ),
    ],
  );

  const tApiKey = 'sk-test-key';

  const tRequest = AiRequest(
    messages: [AiMessage(role: AiRole.user, content: 'Hello')],
    providerId: 'openai',
    modelId: 'gpt-4o',
  );

  const tResponse = AiResponse(text: 'Hi there');
  const tChunk = AiChunk(delta: 'Hi', done: true, finishReason: 'stop');

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types like
    // Either, so we register them explicitly.
    provideDummy<Either<Failure, AiResponse>>(const Right(tResponse));
    provideDummy<Either<Failure, String?>>(const Right(null));

    mockRegistry = MockAiProviderRegistry();
    mockAdapterFactory = MockAiAdapterFactory();
    mockSettingsRepository = MockAiSettingsRepository();
    mockAdapter = MockAiAdapter();

    repository = AiInferenceRepositoryImpl(
      registry: mockRegistry,
      adapterFactory: mockAdapterFactory,
      settingsRepository: mockSettingsRepository,
    );
  });

  group('run', () {
    test(
        'resolves provider, adapter, key and delegates with right baseUrl + key',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(tProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(tApiKey));
      when(mockAdapterFactory.forProtocol(AiWireProtocol.openai))
          .thenReturn(mockAdapter);
      when(mockAdapter.run(
        any,
        apiKey: anyNamed('apiKey'),
        baseUrl: anyNamed('baseUrl'),
      )).thenAnswer((_) async => const Right(tResponse));

      final result = await repository.run(tRequest);

      expect(result, const Right(tResponse));
      verify(mockRegistry.byId('openai'));
      verify(mockAdapterFactory.forProtocol(AiWireProtocol.openai));
      verify(mockAdapter.run(
        tRequest,
        apiKey: tApiKey,
        baseUrl: 'https://api.example.com/v1',
      ));
    });

    test('unknown providerId returns NoProviderConfigured without the factory',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(null);

      final result = await repository.run(tRequest);

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) => expect(failure, isA<NoProviderConfigured>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(mockAdapterFactory.forProtocol(any));
      verifyNever(mockSettingsRepository.getApiKey(any));
    });

    test('re-syncs the registry (ensureReady) before resolving the provider',
        () async {
      // Regression guard: a BYO provider added after the registry first loaded
      // must be visible here, so resolve MUST ensureReady() before byId().
      when(mockRegistry.byId('openai')).thenReturn(tProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => right<Failure, String?>('sk-test-key'));
      when(mockAdapterFactory.forProtocol(any)).thenReturn(mockAdapter);
      when(mockAdapter.run(any, apiKey: anyNamed('apiKey'),
              baseUrl: anyNamed('baseUrl')))
          .thenAnswer(
        (_) async => right<Failure, AiResponse>(
          const AiResponse(text: 'ok'),
        ),
      );

      await repository.run(tRequest);

      verify(mockRegistry.ensureReady()).called(1);
    });

    test('user/BYO provider with no stored key is NOT blocked (key optional)',
        () async {
      when(mockRegistry.byId('byo_ollama')).thenReturn(tByoProvider);
      when(mockSettingsRepository.getApiKey('byo_ollama'))
          .thenAnswer((_) async => right<Failure, String?>(null));
      when(mockAdapterFactory.forProtocol(any)).thenReturn(mockAdapter);
      when(mockAdapter.run(any, apiKey: anyNamed('apiKey'),
              baseUrl: anyNamed('baseUrl')))
          .thenAnswer(
        (_) async => right<Failure, AiResponse>(const AiResponse(text: 'ok')),
      );

      final result = await repository.run(
        const AiRequest(
          messages: [AiMessage(role: AiRole.user, content: 'Hello')],
          providerId: 'byo_ollama',
          modelId: 'qwen2.5:7b',
        ),
      );

      expect(result.isRight(), isTrue);
      // Delegated to the adapter with a null key + the BYO base URL.
      verify(mockAdapter.run(any,
              apiKey: null, baseUrl: 'http://localhost:11434/v1'))
          .called(1);
    });

    test('provider requiring a key with none stored returns MissingApiKey',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(tProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(null));

      final result = await repository.run(tRequest);

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(mockAdapterFactory.forProtocol(any));
    });

    test('empty stored key for a key-requiring provider returns MissingApiKey',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(tProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(''));

      final result = await repository.run(tRequest);

      result.fold(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(mockAdapterFactory.forProtocol(any));
    });

    test(
        'anthropic provider with null apiBaseUrl resolves to '
        'https://api.anthropic.com (no doubled /v1) [H2]', () async {
      // No explicit base URL → the repo must supply the anthropic default. It
      // must be exactly `https://api.anthropic.com`; the adapter appends
      // `/v1/messages`, so any trailing `/v1` here would double it (404).
      when(mockRegistry.byId('anthropic')).thenReturn(tAnthropicProvider);
      when(mockSettingsRepository.getApiKey('anthropic'))
          .thenAnswer((_) async => const Right(tApiKey));
      when(mockAdapterFactory.forProtocol(AiWireProtocol.anthropic))
          .thenReturn(mockAdapter);
      when(mockAdapter.run(any,
              apiKey: anyNamed('apiKey'), baseUrl: anyNamed('baseUrl')))
          .thenAnswer((_) async => const Right(tResponse));

      final result = await repository.run(
        const AiRequest(
          messages: [AiMessage(role: AiRole.user, content: 'Hello')],
          providerId: 'anthropic',
          modelId: 'claude-sonnet-4',
        ),
      );

      expect(result.isRight(), isTrue);
      verify(mockAdapterFactory.forProtocol(AiWireProtocol.anthropic));
      verify(mockAdapter.run(
        any,
        apiKey: tApiKey,
        baseUrl: 'https://api.anthropic.com',
      ));
    });

    test('azure provider with null apiBaseUrl returns NoProviderConfigured [L14]',
        () async {
      // Azure has no fixed endpoint, so a missing base URL must fail closed with
      // a typed config failure rather than dialing a placeholder host.
      when(mockRegistry.byId('azure')).thenReturn(tAzureProvider);
      when(mockSettingsRepository.getApiKey('azure'))
          .thenAnswer((_) async => const Right(tApiKey));

      final result = await repository.run(
        const AiRequest(
          messages: [AiMessage(role: AiRole.user, content: 'Hello')],
          providerId: 'azure',
          modelId: 'gpt-4o',
        ),
      );

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) => expect(failure, isA<NoProviderConfigured>()),
        (_) => fail('expected a Left'),
      );
      // Fails closed before resolving an adapter.
      verifyNever(mockAdapterFactory.forProtocol(any));
    });

    test(
        'model with providerOverride shape=responses delegates a request with '
        'shape=responses', () async {
      when(mockRegistry.byId('openai')).thenReturn(tResponsesProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(tApiKey));
      when(mockAdapterFactory.forProtocol(AiWireProtocol.openai))
          .thenReturn(mockAdapter);
      when(mockAdapter.run(any,
              apiKey: anyNamed('apiKey'), baseUrl: anyNamed('baseUrl')))
          .thenAnswer((_) async => const Right(tResponse));

      await repository.run(
        const AiRequest(
          messages: [AiMessage(role: AiRole.user, content: 'Hello')],
          providerId: 'openai',
          modelId: 'gpt-5-responses',
        ),
      );

      final captured = verify(mockAdapter.run(
        captureAny,
        apiKey: anyNamed('apiKey'),
        baseUrl: anyNamed('baseUrl'),
      )).captured.single as AiRequest;
      expect(captured.shape, AiRequestShape.responses);
    });

    test(
        'model without a responses override delegates a completions-shape request',
        () async {
      // Same provider/model id but no providerOverride → the request passes
      // through with the default completions shape.
      final provider = AiProvider(
        id: 'openai',
        name: 'OpenAI',
        npm: '@ai-sdk/openai',
        doc: 'https://example.com',
        env: const ['OPENAI_API_KEY'],
        apiBaseUrl: 'https://api.example.com/v1',
        kind: AiProviderKind.cloud,
        wireProtocol: AiWireProtocol.openai,
        source: AiProviderSource.catalog,
        models: [buildModel(id: 'gpt-4o', providerId: 'openai')],
      );
      when(mockRegistry.byId('openai')).thenReturn(provider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(tApiKey));
      when(mockAdapterFactory.forProtocol(AiWireProtocol.openai))
          .thenReturn(mockAdapter);
      when(mockAdapter.run(any,
              apiKey: anyNamed('apiKey'), baseUrl: anyNamed('baseUrl')))
          .thenAnswer((_) async => const Right(tResponse));

      await repository.run(tRequest);

      final captured = verify(mockAdapter.run(
        captureAny,
        apiKey: anyNamed('apiKey'),
        baseUrl: anyNamed('baseUrl'),
      )).captured.single as AiRequest;
      expect(captured.shape, AiRequestShape.completions);
    });
  });

  group('stream', () {
    test(
        'resolves provider, adapter, key and delegates with right baseUrl + key',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(tProvider);
      when(mockSettingsRepository.getApiKey('openai'))
          .thenAnswer((_) async => const Right(tApiKey));
      when(mockAdapterFactory.forProtocol(AiWireProtocol.openai))
          .thenReturn(mockAdapter);
      when(mockAdapter.stream(
        any,
        apiKey: anyNamed('apiKey'),
        baseUrl: anyNamed('baseUrl'),
      )).thenAnswer(
        (_) => Stream.fromIterable(const [Right(tChunk)]),
      );

      final emissions = await repository.stream(tRequest).toList();

      expect(emissions, const [Right(tChunk)]);
      verify(mockRegistry.byId('openai'));
      verify(mockAdapterFactory.forProtocol(AiWireProtocol.openai));
      verify(mockAdapter.stream(
        tRequest,
        apiKey: tApiKey,
        baseUrl: 'https://api.example.com/v1',
      ));
    });

    test('unknown providerId yields a single NoProviderConfigured Left',
        () async {
      when(mockRegistry.byId('openai')).thenReturn(null);

      final emissions = await repository.stream(tRequest).toList();

      expect(emissions.length, 1);
      emissions.single.fold(
        (failure) => expect(failure, isA<NoProviderConfigured>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(mockAdapterFactory.forProtocol(any));
    });
  });
}
