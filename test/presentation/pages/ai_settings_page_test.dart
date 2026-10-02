import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_capability.dart';
import 'package:nightmail/domain/entities/ai/ai_decision.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';
import 'package:nightmail/domain/repositories/ai/ai_catalog_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_inference_repository.dart';
import 'package:nightmail/domain/repositories/ai/ai_settings_repository.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/ai/ai_settings_cubit.dart';
import 'package:nightmail/presentation/pages/settings/ai_settings_page.dart';

import 'ai_settings_page_test.mocks.dart';

/// The AI settings page with one System One provider (Jev) and one chat
/// provider (Ollama) configured. Exercises what the page itself decides:
/// which providers each Features row offers, that picking a model commits
/// routing, and that a System One tile carries the "Test decision" probe.
@GenerateMocks([AiCatalogRepository, AiSettingsRepository, AiInferenceRepository])
void main() {
  late MockAiCatalogRepository catalog;
  late MockAiSettingsRepository settings;
  late MockAiInferenceRepository inference;

  const jevLatest = AiModel(
    id: 'jev-latest',
    providerId: 'jev',
    name: 'Jev (latest)',
    attachment: false,
    reasoning: false,
    toolCall: false,
    openWeights: false,
    releaseDate: '',
    lastUpdated: '',
    inputModalities: ['text'],
    outputModalities: ['text'],
    contextLimit: 0,
    outputLimit: 0,
  );

  const jev = AiProvider(
    id: 'jev',
    name: 'TypeSafe Jev (System One)',
    npm: '@typesafe-ai/sdk',
    doc: '',
    env: ['TYPESAFE_API_KEY'],
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.systemOne,
    source: AiProviderSource.catalog,
    models: [jevLatest],
  );

  const ollama = AiProvider(
    id: 'ollama',
    name: 'Ollama (local)',
    npm: 'ollama-ai-provider',
    doc: '',
    env: [],
    kind: AiProviderKind.local,
    wireProtocol: AiWireProtocol.ollama,
    source: AiProviderSource.catalog,
  );

  setUp(() {
    // Mockito cannot synthesise dummy values for the sealed `Either` type, so
    // one is registered per return shape the page can touch when unstubbed.
    provideDummy<Either<Failure, List<AiProvider>>>(const Right([]));
    provideDummy<Either<Failure, AiProvider>>(const Right(ollama));
    provideDummy<Either<Failure, List<AiModel>>>(const Right([]));
    provideDummy<Either<Failure, List<String>>>(const Right([]));
    provideDummy<Either<Failure, AiRouting?>>(const Right(null));
    provideDummy<Either<Failure, bool>>(const Right(false));
    provideDummy<Either<Failure, int>>(const Right(0));
    provideDummy<Either<Failure, Unit>>(Right(unit));
    provideDummy<Either<Failure, String?>>(const Right(null));
    provideDummy<Either<Failure, AiResponse>>(
      const Right(AiResponse(text: '')),
    );
    provideDummy<Either<Failure, AiDecisionResponse>>(
      const Right(AiDecisionResponse(model: '', answers: {})),
    );

    catalog = MockAiCatalogRepository();
    settings = MockAiSettingsRepository();
    inference = MockAiInferenceRepository();

    when(catalog.getProviders(forceRefresh: anyNamed('forceRefresh')))
        .thenAnswer((_) async => const Right([jev, ollama]));
    when(catalog.getModelsForProvider('jev'))
        .thenAnswer((_) async => const Right([jevLatest]));
    when(catalog.listLiveModels(
      baseUrl: anyNamed('baseUrl'),
      apiKey: anyNamed('apiKey'),
      azure: anyNamed('azure'),
    )).thenAnswer((_) async => const Right(['llama3.3']));
    when(settings.getConfiguredProviders())
        .thenAnswer((_) async => const Right([jev, ollama]));
    when(settings.getRouting(any)).thenAnswer((_) async => const Right(null));
    when(settings.getAllowCloudForBodies())
        .thenAnswer((_) async => const Right(false));
    when(settings.getAgentMaxRounds()).thenAnswer((_) async => const Right(5));
    when(settings.getAgentMaxToolCallsPerRound())
        .thenAnswer((_) async => const Right(8));
    when(settings.getApiKey(any)).thenAnswer((_) async => const Right(null));
    when(settings.setRouting(
      capability: anyNamed('capability'),
      providerId: anyNamed('providerId'),
      modelId: anyNamed('modelId'),
    )).thenAnswer((_) async => Right(unit));

    // The page resolves its cubit and the two repositories from get_it, the
    // same way the running app does.
    sl.registerFactory<AiSettingsCubit>(
      () => AiSettingsCubit(
        catalogRepository: catalog,
        settingsRepository: settings,
      ),
    );
    sl.registerSingleton<AiCatalogRepository>(catalog);
    sl.registerSingleton<AiInferenceRepository>(inference);
  });

  tearDown(() => sl.reset());

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AiSettingsPage())),
    );
    await tester.pumpAndSettle();
  }

  List<String?> itemsOf(WidgetTester tester, int index) {
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>).at(index),
    );
    return [for (final item in dropdown.items!) item.value];
  }

  testWidgets('Compose offers only chat providers; Triage only decision ones',
      (tester) async {
    await pumpPage(tester);

    expect(find.text('Compose'), findsOneWidget);
    expect(find.text('Triage'), findsOneWidget);
    // Two provider dropdowns (Compose, Triage); no model picked yet.
    expect(find.byType(DropdownButton<String>), findsNWidgets(2));
    expect(itemsOf(tester, 0), ['ollama']);
    expect(itemsOf(tester, 1), ['jev']);
  });

  testWidgets('a configured System One provider is badged "Decisions"',
      (tester) async {
    await pumpPage(tester);

    // Only the Jev tile carries it — Ollama is a chat runtime.
    expect(find.text('Decisions'), findsOneWidget);
    expect(find.text('TypeSafe Jev (System One)'), findsOneWidget);
    expect(find.text('Ollama (local)'), findsOneWidget);
  });

  testWidgets('picking a Triage provider then a model commits the routing',
      (tester) async {
    await pumpPage(tester);

    // Open the Triage provider dropdown and pick Jev (the menu's copy of the
    // name is the last one in the tree; the first is the configured tile).
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TypeSafe Jev (System One)').last);
    await tester.pumpAndSettle();

    // Jev's static catalog models now feed a third dropdown (Triage's model).
    expect(find.byType(DropdownButton<String>), findsNWidgets(3));
    expect(itemsOf(tester, 2), ['jev-latest']);

    await tester.tap(find.byType(DropdownButton<String>).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jev (latest)').last);
    await tester.pumpAndSettle();

    verify(settings.setRouting(
      capability: AiCapability.triage,
      providerId: 'jev',
      modelId: 'jev-latest',
    )).called(1);
    expect(find.text('Triage will use jev-latest'), findsOneWidget);
  });

  testWidgets('"Test decision" on a System One tile runs the probe and shows '
      'the typed answers', (tester) async {
    when(inference.decide(any)).thenAnswer(
      (_) async => const Right(
        AiDecisionResponse(
          model: 'jev-1.13.0',
          answers: {
            'urgency': AiDecisionAnswer(
              type: AiDecisionQuestionType.score,
              score: 1.4,
              legend: {
                '0': 'no time pressure',
                '1': 'needs attention soon',
                '2': 'blocking issue or hard deadline',
              },
            ),
            'needs_reply': AiDecisionAnswer(
              type: AiDecisionQuestionType.noul,
              probability: 0.91,
            ),
            'category': AiDecisionAnswer(
              type: AiDecisionQuestionType.choice,
              choice: 'billing',
              probabilities: {'billing': 0.88, 'technical': 0.1, 'other': 0.02},
            ),
          },
        ),
      ),
    );
    await pumpPage(tester);

    // Expand the Jev tile.
    await tester.tap(find.text('TypeSafe Jev (System One)'));
    await tester.pumpAndSettle();
    expect(find.text('Test decision'), findsOneWidget);
    // The Jev endpoint is shown, and the key field is offered (keyed provider).
    expect(find.text('https://api.typesafe.ai/v1'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);

    await tester.tap(find.text('Test decision'));
    await tester.pumpAndSettle();

    final request =
        verify(inference.decide(captureAny)).captured.single as AiDecisionRequest;
    expect(request.providerId, 'jev');
    // No Triage route yet → the provider's first catalog model is used.
    expect(request.modelId, 'jev-latest');
    expect(request.questions.keys, containsAll(['urgency', 'needs_reply', 'category']));
    expect(request.state, isA<Map<String, Object?>>());

    expect(
      find.text(
        'jev-1.13.0 · urgency: needs attention soon (1.4) · '
        'needs_reply: yes 91% · category: billing 88%',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a probe failure is shown in place of the result',
      (tester) async {
    when(inference.decide(any)).thenAnswer(
      (_) async => const Left(
        ProviderUnreachable(
          message: 'Could not reach the decision provider. Check that the '
              'server is running and try again.',
        ),
      ),
    );
    await pumpPage(tester);

    await tester.tap(find.text('TypeSafe Jev (System One)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test decision'));
    await tester.pumpAndSettle();

    expect(find.textContaining('server is running'), findsOneWidget);
  });

  testWidgets('Triage explains what to add when no decision provider exists',
      (tester) async {
    when(settings.getConfiguredProviders())
        .thenAnswer((_) async => const Right([ollama]));
    await pumpPage(tester);

    expect(
      find.text('Add a System One provider (Jev, Laya-MLX) to enable.'),
      findsOneWidget,
    );
    // Compose still has its provider dropdown; Triage has none to offer.
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(itemsOf(tester, 0), ['ollama']);
  });
}
