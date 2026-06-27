import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';

void main() {
  AiProvider provider({
    required String id,
    required AiWireProtocol wireProtocol,
    String? apiBaseUrl,
    List<String> env = const [],
  }) {
    return AiProvider(
      id: id,
      name: id,
      npm: '',
      doc: '',
      env: env,
      apiBaseUrl: apiBaseUrl,
      kind: AiProviderKind.cloud,
      wireProtocol: wireProtocol,
      source: AiProviderSource.catalog,
    );
  }

  group('defaultBaseUrl', () {
    test('an explicit apiBaseUrl wins over any built-in default', () {
      final p = provider(
        id: 'openai',
        wireProtocol: AiWireProtocol.openai,
        apiBaseUrl: 'https://proxy.example.com/v1',
      );
      expect(p.defaultBaseUrl, 'https://proxy.example.com/v1');
    });

    test('an empty apiBaseUrl falls back to the built-in default', () {
      final p = provider(
        id: 'openai',
        wireProtocol: AiWireProtocol.openai,
        apiBaseUrl: '',
      );
      expect(p.defaultBaseUrl, 'https://api.openai.com/v1');
    });

    const expected = <String, ({AiWireProtocol protocol, String url})>{
      'openai': (
        protocol: AiWireProtocol.openai,
        url: 'https://api.openai.com/v1',
      ),
      'anthropic': (
        protocol: AiWireProtocol.anthropic,
        url: 'https://api.anthropic.com',
      ),
      'google': (
        protocol: AiWireProtocol.google,
        url: 'https://generativelanguage.googleapis.com/v1beta',
      ),
      'groq': (
        protocol: AiWireProtocol.openai,
        url: 'https://api.groq.com/openai/v1',
      ),
      'mistral': (
        protocol: AiWireProtocol.openai,
        url: 'https://api.mistral.ai/v1',
      ),
      'xai': (protocol: AiWireProtocol.openai, url: 'https://api.x.ai/v1'),
      'deepseek': (
        protocol: AiWireProtocol.openai,
        url: 'https://api.deepseek.com',
      ),
      'cerebras': (
        protocol: AiWireProtocol.openai,
        url: 'https://api.cerebras.ai/v1',
      ),
    };

    for (final entry in expected.entries) {
      test('byId "${entry.key}" resolves to its first-party endpoint', () {
        final p = provider(id: entry.key, wireProtocol: entry.value.protocol);
        expect(p.defaultBaseUrl, entry.value.url);
      });
    }

    test('ollama protocol falls back to the localhost default', () {
      final p = provider(id: 'byo-ollama', wireProtocol: AiWireProtocol.ollama);
      expect(p.defaultBaseUrl, 'http://localhost:11434/v1');
    });

    test(
        'a google-family but non-first-party id (google-vertex) with no '
        'apiBaseUrl resolves to null [M2]', () {
      final p = provider(
        id: 'google-vertex',
        wireProtocol: AiWireProtocol.google,
      );
      expect(p.defaultBaseUrl, isNull);
    });

    test(
        'an anthropic-family but non-first-party id with no apiBaseUrl '
        'resolves to null [M2]', () {
      final p = provider(
        id: 'anthropic-bedrock',
        wireProtocol: AiWireProtocol.anthropic,
      );
      expect(p.defaultBaseUrl, isNull);
    });

    test('an unknown openai-compatible host with no apiBaseUrl → null', () {
      final p = provider(id: 'some-proxy', wireProtocol: AiWireProtocol.openai);
      expect(p.defaultBaseUrl, isNull);
    });

    test('an azure provider with no apiBaseUrl → null', () {
      final p = provider(id: 'azure', wireProtocol: AiWireProtocol.azure);
      expect(p.defaultBaseUrl, isNull);
    });
  });

  group('requiresApiKey', () {
    test('true when the provider declares any env var', () {
      final p = provider(
        id: 'openai',
        wireProtocol: AiWireProtocol.openai,
        env: const ['OPENAI_API_KEY'],
      );
      expect(p.requiresApiKey, isTrue);
    });

    test('false when the provider declares no env var', () {
      final p = provider(id: 'byo-ollama', wireProtocol: AiWireProtocol.ollama);
      expect(p.requiresApiKey, isFalse);
    });
  });
}
