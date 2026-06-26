import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/models/ai/ai_catalog_mapper.dart';
import 'package:nightmail/domain/entities/ai/ai_model.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';

// NOTE: [AiCatalogMapper.parseCatalog] is a pure static function with no
// injected collaborators, so there is nothing to mock here — the repo's
// mockito/@GenerateMocks convention (see get_emails_test.dart) only applies to
// tests of types that depend on a repository/datasource. This test exercises the
// derivation + field round-tripping directly against a representative api.json
// fragment, covering finding H3.
void main() {
  // A small but representative slice of the models.dev `api.json` document: the
  // top level is an object keyed by provider id; each provider's `models` is an
  // object keyed by model id. Covers every wireProtocol/kind derivation branch
  // plus the polymorphic/optional model fields.
  final apiJson = <String, dynamic>{
    'anthropic': {
      'id': 'anthropic',
      'name': 'Anthropic',
      'npm': '@ai-sdk/anthropic',
      'doc': 'https://docs.anthropic.com',
      'env': ['ANTHROPIC_API_KEY'],
      'api': 'https://api.anthropic.com',
      'models': {
        'claude-sonnet-4': {
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
          'attachment': true,
          'reasoning': true,
          'tool_call': true,
          'open_weights': false,
          'release_date': '2026-01-01',
          'last_updated': '2026-02-01',
          'temperature': true,
          'structured_output': true,
          'family': 'claude',
          'status': 'beta',
          'knowledge': '2025-12',
          'modalities': {
            'input': ['text', 'image'],
            'output': ['text'],
          },
          'limit': {
            'context': 200000,
            'output': 64000,
            'input': 190000,
          },
          'cost': {
            'input': 3.0,
            'output': 15.0,
            'cache_read': 0.3,
            'cache_write': 3.75,
          },
          // Object form of `interleaved` → normalized to its `field` value.
          'interleaved': {'field': 'reasoning_content'},
          'provider': {'shape': 'responses'},
        },
      },
    },
    'google': {
      'id': 'google',
      'name': 'Google Generative AI',
      'npm': '@ai-sdk/google',
      'env': ['GOOGLE_GENERATIVE_AI_API_KEY'],
      'api': 'https://generativelanguage.googleapis.com/v1beta/openai',
      'models': {
        'gemini-2.5-pro': {
          'id': 'gemini-2.5-pro',
          'name': 'Gemini 2.5 Pro',
          // `interleaved` in bool form → null field.
          'interleaved': false,
          'limit': {'context': 1000000, 'output': 65536},
        },
      },
    },
    'azure': {
      'id': 'azure',
      'name': 'Azure OpenAI',
      'npm': '@ai-sdk/azure',
      'models': {
        'gpt-4o': {'id': 'gpt-4o', 'name': 'GPT-4o'},
      },
    },
    'ollama': {
      'id': 'ollama',
      'name': 'Ollama',
      'npm': 'ollama-ai-provider',
      'models': {
        'llama3.3': {
          'id': 'llama3.3',
          'name': 'Llama 3.3',
          // No `cost`/`status`/`temperature` (free local model) → defaults/null.
          'limit': {'context': 128000, 'output': 8192},
        },
      },
    },
    'lmstudio': {
      'id': 'lmstudio',
      'name': 'LM Studio',
      'npm': 'lmstudio-ai-provider',
      'models': {
        'local-model': {'id': 'local-model', 'name': 'Local Model'},
      },
    },
    'llama': {
      'id': 'llama',
      'name': 'Llama',
      'npm': 'some-llama-package',
      'models': {
        'llama-x': {'id': 'llama-x', 'name': 'Llama X'},
      },
    },
    // Unknown npm package → defaults to the OpenAI-compatible adapter + cloud.
    'mystery': {
      'id': 'mystery',
      'name': 'Mystery Provider',
      'npm': '@ai-sdk/mystery',
      'models': {
        'mystery-1': {'id': 'mystery-1', 'name': 'Mystery 1'},
      },
    },
  };

  late List<AiProvider> providers;

  AiProvider providerById(String id) =>
      providers.firstWhere((p) => p.id == id);

  setUp(() {
    providers = AiCatalogMapper.parseCatalog(apiJson);
  });

  group('AiCatalogMapper.parseCatalog', () {
    test('parses one AiProvider per top-level entry, tagged as catalog', () {
      expect(providers.length, apiJson.length);
      expect(
        providers.every((p) => p.source == AiProviderSource.catalog),
        isTrue,
      );
    });

    test('skips non-object top-level entries', () {
      final result = AiCatalogMapper.parseCatalog(<String, dynamic>{
        'anthropic': apiJson['anthropic'],
        'garbage': 'not-a-map',
        'also_garbage': 42,
      });
      expect(result.map((p) => p.id), ['anthropic']);
    });

    group('wireProtocol derivation', () {
      test('@ai-sdk/anthropic → anthropic', () {
        expect(
          providerById('anthropic').wireProtocol,
          AiWireProtocol.anthropic,
        );
      });

      test('@ai-sdk/google → google', () {
        expect(providerById('google').wireProtocol, AiWireProtocol.google);
      });

      test('npm containing azure → azure', () {
        expect(providerById('azure').wireProtocol, AiWireProtocol.azure);
      });

      test('ollama/lmstudio/llama npm → ollama', () {
        expect(providerById('ollama').wireProtocol, AiWireProtocol.ollama);
        expect(providerById('lmstudio').wireProtocol, AiWireProtocol.ollama);
        expect(providerById('llama').wireProtocol, AiWireProtocol.ollama);
      });

      test('unknown npm → openai (default)', () {
        expect(providerById('mystery').wireProtocol, AiWireProtocol.openai);
      });
    });

    group('kind derivation', () {
      test('ollama/lmstudio/llama provider id → local', () {
        expect(providerById('ollama').kind, AiProviderKind.local);
        expect(providerById('lmstudio').kind, AiProviderKind.local);
        expect(providerById('llama').kind, AiProviderKind.local);
      });

      test('every other provider id → cloud', () {
        expect(providerById('anthropic').kind, AiProviderKind.cloud);
        expect(providerById('google').kind, AiProviderKind.cloud);
        expect(providerById('azure').kind, AiProviderKind.cloud);
        expect(providerById('mystery').kind, AiProviderKind.cloud);
      });
    });

    group('provider scalar fields', () {
      test('apiBaseUrl comes from `api`', () {
        expect(
          providerById('anthropic').apiBaseUrl,
          'https://api.anthropic.com',
        );
        expect(
          providerById('google').apiBaseUrl,
          'https://generativelanguage.googleapis.com/v1beta/openai',
        );
      });

      test('apiBaseUrl is null when `api` is absent', () {
        expect(providerById('azure').apiBaseUrl, isNull);
      });

      test('env / doc fall back to safe defaults', () {
        final google = providerById('google');
        expect(google.env, ['GOOGLE_GENERATIVE_AI_API_KEY']);
        // `doc` absent in the fragment → empty string, not null.
        expect(google.doc, '');
        expect(providerById('anthropic').env, ['ANTHROPIC_API_KEY']);
      });
    });

    group('model field round-trips', () {
      AiModel modelOf(String providerId, String modelId) =>
          providerById(providerId).models.firstWhere((m) => m.id == modelId);

      test('limit maps to context/output/input', () {
        final m = modelOf('anthropic', 'claude-sonnet-4');
        expect(m.contextLimit, 200000);
        expect(m.outputLimit, 64000);
        expect(m.inputLimit, 190000);
      });

      test('absent limit.input → null', () {
        expect(modelOf('google', 'gemini-2.5-pro').inputLimit, isNull);
      });

      test('cost tiers map through', () {
        final m = modelOf('anthropic', 'claude-sonnet-4');
        expect(m.costInput, 3.0);
        expect(m.costOutput, 15.0);
        expect(m.costCacheRead, 0.3);
        expect(m.costCacheWrite, 3.75);
      });

      test('absent cost → null fields', () {
        final m = modelOf('ollama', 'llama3.3');
        expect(m.costInput, isNull);
        expect(m.costOutput, isNull);
      });

      test('status string maps to enum, absent → null', () {
        expect(
          modelOf('anthropic', 'claude-sonnet-4').status,
          AiModelStatus.beta,
        );
        expect(modelOf('ollama', 'llama3.3').status, isNull);
      });

      test('interleaved object → field value; bool → null', () {
        expect(
          modelOf('anthropic', 'claude-sonnet-4').interleavedField,
          'reasoning_content',
        );
        expect(modelOf('google', 'gemini-2.5-pro').interleavedField, isNull);
      });

      test('modalities map to input/output lists', () {
        final m = modelOf('anthropic', 'claude-sonnet-4');
        expect(m.inputModalities, ['text', 'image']);
        expect(m.outputModalities, ['text']);
      });

      test('absent modalities → empty lists', () {
        final m = modelOf('google', 'gemini-2.5-pro');
        expect(m.inputModalities, isEmpty);
        expect(m.outputModalities, isEmpty);
      });

      test('per-model provider override (shape) is kept as-is', () {
        final m = modelOf('anthropic', 'claude-sonnet-4');
        expect(m.providerOverride, {'shape': 'responses'});
      });

      test('bool flags default to false when absent', () {
        final m = modelOf('google', 'gemini-2.5-pro');
        expect(m.attachment, isFalse);
        expect(m.reasoning, isFalse);
        expect(m.toolCall, isFalse);
        expect(m.openWeights, isFalse);
      });

      test('providerId is propagated onto each model', () {
        expect(
          modelOf('anthropic', 'claude-sonnet-4').providerId,
          'anthropic',
        );
      });
    });
  });
}
