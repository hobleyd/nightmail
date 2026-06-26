import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/ai/ai_catalog_cache_datasource.dart';
import 'package:nightmail/data/datasources/ai/ai_config_datasource.dart';
import 'package:nightmail/data/datasources/ai/ai_provider_registry.dart';
import 'package:nightmail/data/datasources/ai/models_dev_catalog_datasource.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';

import 'ai_provider_registry_test.mocks.dart';

@GenerateMocks([
  ModelsDevCatalogDatasource,
  AiCatalogCacheDatasource,
  AiConfigDatasource,
])
void main() {
  late AiProviderRegistry registry;
  late MockModelsDevCatalogDatasource mockCatalog;
  late MockAiCatalogCacheDatasource mockCache;
  late MockAiConfigDatasource mockConfig;

  // --- Inline fixtures --------------------------------------------------------

  AiModel buildModel({
    required String id,
    required String providerId,
    String? name,
  }) {
    return AiModel(
      id: id,
      providerId: providerId,
      name: name ?? id,
      attachment: false,
      reasoning: false,
      toolCall: true,
      openWeights: false,
      releaseDate: '2026-01-01',
      lastUpdated: '2026-01-01',
      inputModalities: const ['text'],
      outputModalities: const ['text'],
      contextLimit: 200000,
      outputLimit: 8192,
    );
  }

  AiProvider buildProvider({
    required String id,
    AiProviderKind kind = AiProviderKind.cloud,
    AiProviderSource source = AiProviderSource.catalog,
    List<String> env = const [],
    List<AiModel>? models,
    String? apiBaseUrl,
  }) {
    return AiProvider(
      id: id,
      name: id,
      npm: '@ai-sdk/$id',
      doc: 'https://example.com/$id',
      env: env,
      kind: kind,
      wireProtocol: AiWireProtocol.openai,
      source: source,
      apiBaseUrl: apiBaseUrl,
      models: models ?? [buildModel(id: '$id-model', providerId: id)],
    );
  }

  // A representative catalog: a cloud provider needing a key, and a local one.
  final tAnthropic = buildProvider(
    id: 'anthropic',
    kind: AiProviderKind.cloud,
    source: AiProviderSource.catalog,
    env: const ['ANTHROPIC_API_KEY'],
    models: [
      buildModel(id: 'claude-sonnet-4', providerId: 'anthropic'),
      buildModel(id: 'claude-haiku-4', providerId: 'anthropic'),
    ],
  );
  final tOllama = buildProvider(
    id: 'ollama',
    kind: AiProviderKind.local,
    source: AiProviderSource.catalog,
    env: const [],
    models: [buildModel(id: 'llama3', providerId: 'ollama')],
  );
  final tCatalog = [tAnthropic, tOllama];

  // A BYO/self-hosted user provider with a brand-new id.
  final tUserProvider = buildProvider(
    id: 'my-proxy',
    kind: AiProviderKind.selfHosted,
    source: AiProviderSource.user,
    env: const [],
    models: const [],
  );

  const tRawMap = <String, dynamic>{'anthropic': {}, 'ollama': {}};
  final tRawJson = jsonEncode(tRawMap);

  setUp(() {
    mockCatalog = MockModelsDevCatalogDatasource();
    mockCache = MockAiCatalogCacheDatasource();
    mockConfig = MockAiConfigDatasource();
    registry = AiProviderRegistry(
      catalogDatasource: mockCatalog,
      cacheDatasource: mockCache,
      configDatasource: mockConfig,
    );

    // Sensible default stubs; individual tests override as needed.
    when(mockConfig.getConfiguredProviders()).thenAnswer((_) async => const []);
    when(mockCache.read()).thenAnswer((_) async => null);
    when(mockCache.write(
      rawJson: anyNamed('rawJson'),
      fetchedAt: anyNamed('fetchedAt'),
      etag: anyNamed('etag'),
      lastModified: anyNamed('lastModified'),
    )).thenAnswer((_) => Future<void>.value());
  });

  group('merge: catalog ∪ user providers', () {
    test('all() unions catalog and user providers, source-tagged', () async {
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);
      when(mockConfig.getConfiguredProviders())
          .thenAnswer((_) async => [tUserProvider]);

      await registry.load(forceRefresh: true);

      final all = registry.all();
      expect(all.map((p) => p.id), containsAll(['anthropic', 'ollama', 'my-proxy']));
      expect(all.length, 3);

      final catalogEntries =
          all.where((p) => p.source == AiProviderSource.catalog);
      final userEntries = all.where((p) => p.source == AiProviderSource.user);
      expect(catalogEntries.map((p) => p.id),
          containsAll(['anthropic', 'ollama']));
      expect(userEntries.map((p) => p.id), ['my-proxy']);
    });

    test(
        'a configured catalog provider overlays its endpoint while keeping '
        'catalog identity + models', () async {
      // e.g. an Azure catalog pick the user gave a per-resource base URL.
      final configured = buildProvider(
        id: 'anthropic',
        source: AiProviderSource.catalog,
        apiBaseUrl: 'https://my-resource.example/openai/v1',
      );
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);
      when(mockConfig.getConfiguredProviders())
          .thenAnswer((_) async => [configured]);

      await registry.load(forceRefresh: true);

      final resolved = registry.byId('anthropic');
      expect(resolved, isNotNull);
      // Endpoint comes from the user's config...
      expect(resolved!.apiBaseUrl, 'https://my-resource.example/openai/v1');
      // ...but the catalog identity and models are preserved.
      expect(resolved.source, AiProviderSource.catalog);
      expect(resolved.models.map((m) => m.id),
          ['claude-sonnet-4', 'claude-haiku-4']);
      // No duplicate id in the merged view.
      expect(registry.all().where((p) => p.id == 'anthropic').length, 1);
    });
  });

  group('query API: byId / byKind / modelsFor', () {
    setUp(() async {
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);
      when(mockConfig.getConfiguredProviders())
          .thenAnswer((_) async => [tUserProvider]);
      await registry.load(forceRefresh: true);
    });

    test('byId returns the matching provider or null', () {
      expect(registry.byId('anthropic'), tAnthropic);
      expect(registry.byId('my-proxy'), tUserProvider);
      expect(registry.byId('does-not-exist'), isNull);
    });

    test('byKind returns the right subset', () {
      expect(registry.byKind(AiProviderKind.cloud).map((p) => p.id),
          ['anthropic']);
      expect(
          registry.byKind(AiProviderKind.local).map((p) => p.id), ['ollama']);
      expect(registry.byKind(AiProviderKind.selfHosted).map((p) => p.id),
          ['my-proxy']);
    });

    test('modelsFor returns the provider models, empty for unknown', () {
      expect(registry.modelsFor('anthropic').map((m) => m.id),
          ['claude-sonnet-4', 'claude-haiku-4']);
      expect(registry.modelsFor('my-proxy'), isEmpty);
      expect(registry.modelsFor('nope'), isEmpty);
    });
  });

  group('stale-while-revalidate', () {
    test('cold start serves from the cache blob when present', () async {
      when(mockCache.read()).thenAnswer(
        (_) async => CachedCatalog(rawJson: tRawJson, fetchedAt: DateTime(2026)),
      );
      when(mockCatalog.parse(tRawJson)).thenReturn(tCatalog);
      // Background revalidation fails — the cached catalog must survive.
      when(mockCatalog.fetchRaw()).thenThrow(Exception('offline'));

      await registry.load();

      expect(registry.isLoaded, isTrue);
      expect(registry.all().map((p) => p.id), containsAll(['anthropic', 'ollama']));
      verify(mockCache.read()).called(1);
      verify(mockCatalog.parse(tRawJson)).called(1);
    });

    test('forceRefresh fetches via the datasource and writes raw json to cache',
        () async {
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);

      await registry.load(forceRefresh: true);

      verify(mockCatalog.fetchRaw()).called(1);
      // The registry json-encodes the fetched map and persists that blob.
      final captured = verify(mockCache.write(
        rawJson: captureAnyNamed('rawJson'),
        fetchedAt: anyNamed('fetchedAt'),
        etag: anyNamed('etag'),
        lastModified: anyNamed('lastModified'),
      )).captured.single as String;
      expect(jsonDecode(captured), tRawMap);
      expect(registry.all().map((p) => p.id),
          containsAll(['anthropic', 'ollama']));
    });

    test('cold start with no cache + failed fetch degrades gracefully',
        () async {
      when(mockCache.read()).thenAnswer((_) async => null);
      when(mockCatalog.fetchRaw()).thenThrow(Exception('boom'));

      // Must not throw despite both cache miss and network failure.
      await registry.load();

      expect(registry.isLoaded, isFalse);
      expect(registry.all(), isEmpty);
      verifyNever(mockCache.write(
        rawJson: anyNamed('rawJson'),
        fetchedAt: anyNamed('fetchedAt'),
        etag: anyNamed('etag'),
        lastModified: anyNamed('lastModified'),
      ));
    });

    test('a failure loading user providers does not abort the catalog load',
        () async {
      when(mockConfig.getConfiguredProviders()).thenThrow(Exception('db locked'));
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);

      await registry.load(forceRefresh: true);

      expect(registry.all().map((p) => p.id),
          containsAll(['anthropic', 'ollama']));
    });
  });

  group('availability / requiresApiKey', () {
    setUp(() async {
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);
      await registry.load(forceRefresh: true);
    });

    test('requiresApiKey reflects the provider env, false for unknown', () {
      expect(registry.requiresApiKey('anthropic'), isTrue);
      expect(registry.requiresApiKey('ollama'), isFalse);
      expect(registry.requiresApiKey('unknown'), isFalse);
    });

    test('isAvailable: keyless provider is always available', () {
      expect(registry.isAvailable('ollama', hasApiKey: false), isTrue);
      expect(registry.isAvailable('ollama', hasApiKey: true), isTrue);
    });

    test('isAvailable: keyed provider needs a key', () {
      expect(registry.isAvailable('anthropic', hasApiKey: false), isFalse);
      expect(registry.isAvailable('anthropic', hasApiKey: true), isTrue);
    });

    test('isAvailable: unknown provider is never available', () {
      expect(registry.isAvailable('nope', hasApiKey: true), isFalse);
    });
  });

  // L16: concurrency dedup (`_inFlightRefresh`) + the warm `load()` branch that
  // serves the in-memory catalog and revalidates out of band.
  group('concurrency & warm-path refresh', () {
    test('two concurrent cold load() calls dedup onto a single network fetch',
        () async {
      // Gate the fetch so both load() calls reach `_refreshFromNetwork` and
      // collapse onto the same in-flight future before it resolves.
      final fetchGate = Completer<Map<String, dynamic>>();
      when(mockCatalog.fetchRaw()).thenAnswer((_) => fetchGate.future);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);

      final loads = Future.wait([registry.load(), registry.load()]);
      // Let both load() calls drain their microtask chains (configured
      // providers + cache read) and suspend on the gated fetch.
      await Future<void>.delayed(Duration.zero);
      fetchGate.complete(tRawMap);
      await loads;

      // The shared `_inFlightRefresh` future means exactly one upstream fetch.
      verify(mockCatalog.fetchRaw()).called(1);
      expect(registry.isLoaded, isTrue);
      expect(registry.all().map((p) => p.id),
          containsAll(['anthropic', 'ollama']));
    });

    test(
        'a warm load() serves the in-memory catalog and refreshes in the '
        'background without blocking', () async {
      // Prime the in-memory catalog with a normal cold load.
      when(mockCatalog.fetchRaw()).thenAnswer((_) async => tRawMap);
      when(mockCatalog.parse(any)).thenReturn(tCatalog);
      await registry.load();
      expect(registry.isLoaded, isTrue);

      // Re-arm the fetch so the next (background) revalidation never settles.
      clearInteractions(mockCatalog);
      final pendingFetch = Completer<Map<String, dynamic>>();
      when(mockCatalog.fetchRaw()).thenAnswer((_) => pendingFetch.future);

      // The warm path must return immediately — awaiting the gated background
      // refresh would hang here and time the test out.
      await registry.load();

      // The previously-loaded catalog is still served from memory...
      expect(registry.all().map((p) => p.id),
          containsAll(['anthropic', 'ollama']));
      // ...and a background revalidation was kicked off (still in flight).
      verify(mockCatalog.fetchRaw()).called(1);

      // Drain the background refresh so no pending future outlives the test.
      pendingFetch.complete(tRawMap);
      await Future<void>.delayed(Duration.zero);
    });
  });
}
