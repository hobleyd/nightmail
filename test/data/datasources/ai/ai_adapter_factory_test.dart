import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:nightmail/data/datasources/ai/ai_adapter_factory.dart';
import 'package:nightmail/data/datasources/ai/inference/ai_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';

import 'ai_adapter_factory_test.mocks.dart';

@GenerateMocks([AiAdapter])
void main() {
  late MockAiAdapter mockOpenAiAdapter;
  late MockAiAdapter mockAnthropicAdapter;
  late MockAiAdapter mockAzureAdapter;
  late AiAdapterFactory factory;

  setUp(() {
    mockOpenAiAdapter = MockAiAdapter();
    mockAnthropicAdapter = MockAiAdapter();
    mockAzureAdapter = MockAiAdapter();
    factory = AiAdapterFactory(
      openAiAdapter: mockOpenAiAdapter,
      anthropicAdapter: mockAnthropicAdapter,
      azureAdapter: mockAzureAdapter,
    );
  });

  group('AiAdapterFactory.forProtocol', () {
    test('openai resolves to the OpenAI adapter instance', () {
      expect(
        factory.forProtocol(AiWireProtocol.openai),
        same(mockOpenAiAdapter),
      );
    });

    test('anthropic resolves to the Anthropic adapter instance', () {
      expect(
        factory.forProtocol(AiWireProtocol.anthropic),
        same(mockAnthropicAdapter),
      );
    });

    test('azure resolves to the dedicated Azure (api-key) adapter instance', () {
      expect(
        factory.forProtocol(AiWireProtocol.azure),
        same(mockAzureAdapter),
      );
    });

    test('google resolves to the OpenAI-compatible stand-in adapter', () {
      // Interim: google has no dedicated adapter yet (see source TODO) and
      // falls back to the OpenAI-compatible adapter.
      expect(
        factory.forProtocol(AiWireProtocol.google),
        same(mockOpenAiAdapter),
      );
    });

    test('ollama resolves to the OpenAI-compatible stand-in adapter', () {
      // Interim: ollama has no dedicated adapter yet (see source TODO) and
      // falls back to the OpenAI-compatible adapter.
      expect(
        factory.forProtocol(AiWireProtocol.ollama),
        same(mockOpenAiAdapter),
      );
    });

    test('never throws for any AiWireProtocol value (exhaustiveness contract)',
        () {
      for (final protocol in AiWireProtocol.values) {
        expect(
          () => factory.forProtocol(protocol),
          returnsNormally,
          reason: 'forProtocol must resolve an adapter for $protocol',
        );
        expect(
          factory.forProtocol(protocol),
          isA<AiAdapter>(),
          reason: 'forProtocol must return an AiAdapter for $protocol',
        );
      }
    });
  });
}
