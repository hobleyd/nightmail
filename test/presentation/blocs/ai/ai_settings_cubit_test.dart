import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/repositories/ai/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/presentation/blocs/ai/ai_settings_cubit.dart';
import 'package:nightmail/presentation/blocs/ai/ai_settings_state.dart';

import 'ai_settings_cubit_test.mocks.dart';

@GenerateMocks([AiCatalogRepository, AiSettingsRepository])
void main() {
  late AiSettingsCubit cubit;
  late MockAiCatalogRepository mockCatalog;
  late MockAiSettingsRepository mockSettings;

  // A minimal cloud provider descriptor (no models needed for these tests).
  AiProvider provider(String id, {AiProviderKind kind = AiProviderKind.cloud}) =>
      AiProvider(
        id: id,
        name: id,
        npm: '@ai-sdk/$id',
        doc: 'https://example.com/$id',
        env: const ['API_KEY'],
        kind: kind,
        wireProtocol: AiWireProtocol.openai,
        source: AiProviderSource.catalog,
      );

  setUp(() {
    // Mockito cannot synthesise dummy values for the sealed `Either` type, so
    // we register one per return shape the cubit can touch when unstubbed.
    provideDummy<Either<Failure, List<AiProvider>>>(const Right([]));
    provideDummy<Either<Failure, AiProvider>>(Right(provider('dummy')));
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, bool>>(const Right(false));
    provideDummy<Either<Failure, Unit>>(Right(unit));

    mockCatalog = MockAiCatalogRepository();
    mockSettings = MockAiSettingsRepository();
    cubit = AiSettingsCubit(
      catalogRepository: mockCatalog,
      settingsRepository: mockSettings,
    );
  });

  tearDown(() => cubit.close());

  /// Stubs a fully successful `load()`: a catalog, no routing, no configured
  /// providers, and the cloud-bodies guard off — overridable per test.
  void stubLoad({
    List<AiProvider> providers = const [],
    List<AiProvider> configured = const [],
    Map<AiCapability, AiRouting> routing = const {},
    bool allowCloudForBodies = false,
  }) {
    when(mockCatalog.getProviders(forceRefresh: anyNamed('forceRefresh')))
        .thenAnswer((_) async => Right(providers));
    when(mockSettings.getConfiguredProviders())
        .thenAnswer((_) async => Right(configured));
    when(mockSettings.getRouting(any))
        .thenAnswer((invocation) async =>
            Right(routing[invocation.positionalArguments.first]));
    when(mockSettings.getAllowCloudForBodies())
        .thenAnswer((_) async => Right(allowCloudForBodies));
  }

  group('load', () {
    test('emits loaded with providers, routing, configured and the guard flag',
        () async {
      final providers = [provider('openai'), provider('anthropic')];
      const routing = {
        AiCapability.compose: (providerId: 'openai', modelId: 'gpt-4o'),
      };
      stubLoad(
        providers: providers,
        configured: [provider('openai')],
        routing: routing,
        allowCloudForBodies: true,
      );

      final states = <AiSettingsState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.load();
      await pumpEventQueue();
      await sub.cancel();

      // loading → loaded.
      expect(states.first.status, AiSettingsStatus.loading);
      final loaded = states.last;
      expect(loaded.status, AiSettingsStatus.loaded);
      expect(loaded.providers, providers);
      expect(loaded.configured, [provider('openai')]);
      expect(loaded.routing, routing);
      expect(loaded.allowCloudForBodies, isTrue);
      expect(loaded.errorMessage, isNull);
    });

    test('defaults allowCloudForBodies to false when the guard read fails',
        () async {
      stubLoad();
      when(mockSettings.getAllowCloudForBodies()).thenAnswer(
          (_) async => const Left(CacheFailure(message: 'no row')));

      await cubit.load();

      expect(cubit.state.status, AiSettingsStatus.loaded);
      expect(cubit.state.allowCloudForBodies, isFalse);
    });

    test('emits error when the provider catalog cannot be loaded', () async {
      when(mockCatalog.getProviders(forceRefresh: anyNamed('forceRefresh')))
          .thenAnswer(
              (_) async => const Left(CatalogUnavailable(message: 'offline')));

      await cubit.load();

      expect(cubit.state.status, AiSettingsStatus.error);
      expect(cubit.state.errorMessage, 'offline');
    });
  });

  group('setRouting', () {
    test('persists and merges the new route into state', () async {
      when(mockSettings.setRouting(
        capability: anyNamed('capability'),
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      )).thenAnswer((_) async => Right(unit));

      final states = <AiSettingsState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.setRouting(
        capability: AiCapability.compose,
        providerId: 'openai',
        modelId: 'gpt-4o',
      );
      await pumpEventQueue();
      await sub.cancel();

      verify(mockSettings.setRouting(
        capability: AiCapability.compose,
        providerId: 'openai',
        modelId: 'gpt-4o',
      ));
      expect(states.last.routing[AiCapability.compose],
          (providerId: 'openai', modelId: 'gpt-4o'));
    });

    test('emits error and leaves routing untouched on failure', () async {
      when(mockSettings.setRouting(
        capability: anyNamed('capability'),
        providerId: anyNamed('providerId'),
        modelId: anyNamed('modelId'),
      )).thenAnswer(
          (_) async => const Left(CacheFailure(message: 'write failed')));

      await cubit.setRouting(
        capability: AiCapability.compose,
        providerId: 'openai',
        modelId: 'gpt-4o',
      );

      expect(cubit.state.status, AiSettingsStatus.error);
      expect(cubit.state.errorMessage, 'write failed');
      expect(cubit.state.routing, isEmpty);
    });
  });

  group('addConfiguredProvider', () {
    test('persists the provider and adds it to the configured list', () async {
      final byo = provider('mybox', kind: AiProviderKind.selfHosted);
      when(mockSettings.addByoProvider(any))
          .thenAnswer((_) async => Right(byo));

      final states = <AiSettingsState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.addConfiguredProvider(byo);
      await pumpEventQueue();
      await sub.cancel();

      verify(mockSettings.addByoProvider(byo));
      expect(states.last.configured, [byo]);
    });
  });

  group('removeProvider', () {
    test('drops the provider and any routing pointing at it', () async {
      // Seed state via a successful load first.
      const routing = {
        AiCapability.compose: (providerId: 'openai', modelId: 'gpt-4o'),
        AiCapability.summarize: (providerId: 'anthropic', modelId: 'opus'),
      };
      stubLoad(
        providers: [provider('openai'), provider('anthropic')],
        configured: [provider('openai'), provider('anthropic')],
        routing: routing,
      );
      await cubit.load();

      when(mockSettings.removeProvider(any))
          .thenAnswer((_) async => Right(unit));

      await cubit.removeProvider('openai');

      verify(mockSettings.removeProvider('openai'));
      expect(cubit.state.configured, [provider('anthropic')]);
      expect(cubit.state.routing.containsKey(AiCapability.compose), isFalse);
      expect(cubit.state.routing[AiCapability.summarize],
          (providerId: 'anthropic', modelId: 'opus'));
    });
  });

  group('setAllowCloudForBodies', () {
    test('persists and emits the new flag', () async {
      when(mockSettings.setAllowCloudForBodies(any))
          .thenAnswer((_) async => Right(unit));

      final states = <AiSettingsState>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.setAllowCloudForBodies(true);
      await pumpEventQueue();
      await sub.cancel();

      verify(mockSettings.setAllowCloudForBodies(true));
      expect(states.last.allowCloudForBodies, isTrue);
    });

    test('emits error and keeps the flag off on failure', () async {
      when(mockSettings.setAllowCloudForBodies(any)).thenAnswer(
          (_) async => const Left(CacheFailure(message: 'write failed')));

      await cubit.setAllowCloudForBodies(true);

      expect(cubit.state.status, AiSettingsStatus.error);
      expect(cubit.state.allowCloudForBodies, isFalse);
    });
  });
}
