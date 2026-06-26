import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/ai_provider_registry.dart';
import 'package:nightmail/data/datasources/ai/provider_models_datasource.dart';
import 'package:nightmail/data/repositories/ai/ai_catalog_repository_impl.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';

import 'ai_catalog_repository_impl_test.mocks.dart';

@GenerateMocks([AiProviderRegistry, ProviderModelsDatasource])
void main() {
  late AiCatalogRepositoryImpl repository;
  late MockAiProviderRegistry mockRegistry;
  late MockProviderModelsDatasource mockProviderModels;

  setUp(() {
    mockRegistry = MockAiProviderRegistry();
    mockProviderModels = MockProviderModelsDatasource();
    repository = AiCatalogRepositoryImpl(
      registry: mockRegistry,
      providerModels: mockProviderModels,
    );
    // Every read first asks the registry to (re)load; default it to a no-op so
    // individual tests only stub the query surface they care about.
    when(mockRegistry.load(forceRefresh: anyNamed('forceRefresh')))
        .thenAnswer((_) async {});
  });

  AiModel buildModel({
    required String id,
    required String providerId,
  }) {
    return AiModel(
      id: id,
      providerId: providerId,
      name: id,
      attachment: false,
      reasoning: false,
      toolCall: true,
      openWeights: false,
      releaseDate: '2026-01-01',
      lastUpdated: '2026-01-01',
      inputModalities: const ['text'],
      outputModalities: const ['text'],
      contextLimit: 128000,
      outputLimit: 4096,
    );
  }

  AiProvider buildProvider({
    required String id,
    List<AiModel> models = const [],
    AiProviderKind kind = AiProviderKind.cloud,
  }) {
    return AiProvider(
      id: id,
      name: id,
      npm: '@ai-sdk/$id',
      doc: 'https://example.com/$id',
      env: const ['API_KEY'],
      kind: kind,
      wireProtocol: AiWireProtocol.openai,
      source: AiProviderSource.catalog,
      models: models,
    );
  }

  group('getProviders', () {
    test('returns CatalogUnavailable when the registry serves nothing',
        () async {
      when(mockRegistry.all()).thenReturn(const []);

      final result = await repository.getProviders();

      expect(result, isA<Left<Failure, List<AiProvider>>>());
      result.match(
        (failure) => expect(failure, isA<CatalogUnavailable>()),
        (_) => fail('expected a Left(CatalogUnavailable)'),
      );
      verify(mockRegistry.load(forceRefresh: false));
    });

    test('returns the registry snapshot when providers exist', () async {
      final providers = [buildProvider(id: 'anthropic')];
      when(mockRegistry.all()).thenReturn(providers);

      final result = await repository.getProviders();

      expect(result, Right<Failure, List<AiProvider>>(providers));
    });

    test('forwards forceRefresh to the registry load', () async {
      when(mockRegistry.all()).thenReturn([buildProvider(id: 'anthropic')]);

      await repository.getProviders(forceRefresh: true);

      verify(mockRegistry.load(forceRefresh: true));
    });
  });

  group('getModelsForProvider', () {
    test('returns CatalogUnavailable when nothing is cached', () async {
      when(mockRegistry.all()).thenReturn(const []);

      final result = await repository.getModelsForProvider('anthropic');

      result.match(
        (failure) => expect(failure, isA<CatalogUnavailable>()),
        (_) => fail('expected a Left(CatalogUnavailable)'),
      );
    });

    test('returns CacheFailure when the provider is unknown', () async {
      when(mockRegistry.all()).thenReturn([buildProvider(id: 'openai')]);
      when(mockRegistry.byId('anthropic')).thenReturn(null);

      final result = await repository.getModelsForProvider('anthropic');

      result.match(
        (failure) => expect(failure, isA<CacheFailure>()),
        (_) => fail('expected a Left(CacheFailure)'),
      );
    });

    test('returns the provider models on success', () async {
      final models = [
        buildModel(id: 'claude-sonnet-4', providerId: 'anthropic'),
      ];
      final provider = buildProvider(id: 'anthropic', models: models);
      when(mockRegistry.all()).thenReturn([provider]);
      when(mockRegistry.byId('anthropic')).thenReturn(provider);
      when(mockRegistry.modelsFor('anthropic')).thenReturn(models);

      final result = await repository.getModelsForProvider('anthropic');

      expect(result, Right<Failure, List<AiModel>>(models));
    });
  });

  group('listLiveModels', () {
    test('short-circuits to an empty list for a blank base URL', () async {
      final result = await repository.listLiveModels(baseUrl: '   ');

      expect(result, const Right<Failure, List<String>>(<String>[]));
      verifyZeroInteractions(mockProviderModels);
    });

    test('delegates to the datasource and returns the model ids', () async {
      when(mockProviderModels.list(
        baseUrl: anyNamed('baseUrl'),
        apiKey: anyNamed('apiKey'),
        azure: anyNamed('azure'),
      )).thenAnswer((_) async => ['gpt-4o', 'gpt-4o-mini']);

      final result = await repository.listLiveModels(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: 'secret',
      );

      // Unwrap and deep-compare: `Right`'s `==` compares the wrapped `List` by
      // reference (non-const lists are never `==`-equal), so assert on contents.
      expect(result.isRight(), isTrue);
      expect(result.getOrElse((_) => const <String>[]),
          ['gpt-4o', 'gpt-4o-mini']);
      verify(mockProviderModels.list(
        baseUrl: 'http://localhost:11434/v1',
        apiKey: 'secret',
        azure: false,
      ));
    });

    test('passes the azure flag through to the datasource', () async {
      when(mockProviderModels.list(
        baseUrl: anyNamed('baseUrl'),
        apiKey: anyNamed('apiKey'),
        azure: anyNamed('azure'),
      )).thenAnswer((_) async => ['my-deployment']);

      await repository.listLiveModels(
        baseUrl: 'https://my-resource.openai.azure.com/openai/v1',
        apiKey: 'key',
        azure: true,
      );

      verify(mockProviderModels.list(
        baseUrl: 'https://my-resource.openai.azure.com/openai/v1',
        apiKey: 'key',
        azure: true,
      ));
    });

    test('maps a datasource throw to Left(ProviderUnreachable)', () async {
      when(mockProviderModels.list(
        baseUrl: anyNamed('baseUrl'),
        apiKey: anyNamed('apiKey'),
        azure: anyNamed('azure'),
      )).thenThrow(Exception('connection refused'));

      final result =
          await repository.listLiveModels(baseUrl: 'http://localhost:11434/v1');

      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left(ProviderUnreachable)'),
      );
    });
  });
}
