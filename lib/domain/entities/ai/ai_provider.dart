import 'package:equatable/equatable.dart';

import 'ai_model.dart';

/// Privacy/hosting classification of an AI provider.
///
/// Derived (not present in models.dev JSON): a known-local provider id maps to
/// [local]; a user-source BYO entry pointing at a custom base URL maps to
/// [selfHosted]; otherwise [cloud].
enum AiProviderKind { cloud, local, selfHosted }

/// The request/response wire shape an adapter must speak to a provider.
///
/// Derived from the provider's `npm` package (and, per model, `provider.shape`).
/// Unknown packages default to [openai] (the OpenAI-compatible adapter).
/// [azure] is the OpenAI shape but authenticated with the `api-key` header
/// (Azure OpenAI / AI Foundry v1 endpoints) rather than a Bearer token.
enum AiWireProtocol { openai, anthropic, google, ollama, azure }

/// Where a provider descriptor originated.
///
/// [catalog] entries come from the models.dev catalog; [user] entries are
/// bring-your-own providers configured locally.
enum AiProviderSource { catalog, user }

/// In-memory descriptor for an AI backend.
///
/// Maps from a models.dev provider entry (see "Schema Mapping" in the AI
/// subsystem design spec). Held by the registry for the session; not mirrored
/// into drift.
class AiProvider extends Equatable {
  const AiProvider({
    required this.id,
    required this.name,
    required this.npm,
    required this.doc,
    required this.env,
    required this.kind,
    required this.wireProtocol,
    required this.source,
    this.apiBaseUrl,
    this.models = const [],
  });

  /// Provider id (= map key in the catalog JSON), e.g. `anthropic`.
  final String id;

  /// Human-readable provider name.
  final String name;

  /// AI-SDK npm package, e.g. `@ai-sdk/anthropic` — drives [wireProtocol].
  final String npm;

  /// Documentation URL.
  final String doc;

  /// Environment variable names that supply the API key.
  ///
  /// Empty means no key is required (see [requiresApiKey]).
  final List<String> env;

  /// Custom API base URL. Absent for most first-party hosted providers.
  final String? apiBaseUrl;

  /// Derived privacy/hosting classification.
  final AiProviderKind kind;

  /// Derived wire protocol used to resolve an adapter.
  final AiWireProtocol wireProtocol;

  /// Whether this descriptor came from the catalog or a user BYO config.
  final AiProviderSource source;

  /// Models offered by this provider. Populated for catalog entries; empty for
  /// user BYO providers whose model list is not enumerated.
  final List<AiModel> models;

  /// True when the provider declares any [env] var, i.e. an API key is needed.
  bool get requiresApiKey => env.isNotEmpty;

  AiProvider copyWith({
    String? apiBaseUrl,
    AiWireProtocol? wireProtocol,
    AiProviderKind? kind,
  }) {
    return AiProvider(
      id: id,
      name: name,
      npm: npm,
      doc: doc,
      env: env,
      kind: kind ?? this.kind,
      wireProtocol: wireProtocol ?? this.wireProtocol,
      source: source,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      models: models,
    );
  }

  @override
  List<Object?> get props => [
        id,
        name,
        npm,
        doc,
        env,
        apiBaseUrl,
        kind,
        wireProtocol,
        source,
        models,
      ];
}
