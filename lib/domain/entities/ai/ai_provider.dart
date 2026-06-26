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

  /// A built-in default endpoint for providers whose models.dev entry carries
  /// no `api` URL but whose endpoint we know — first-party providers
  /// (OpenAI/Anthropic/Google) and a few common OpenAI-compatible hosts.
  ///
  /// Returns null when the user must supply the endpoint themselves: an Azure
  /// per-resource URL, or an OpenAI-compatible host we have no default for.
  /// Used both by inference resolution and to decide whether the settings UI
  /// needs to prompt for a base URL.
  String? get defaultBaseUrl {
    if (apiBaseUrl != null && apiBaseUrl!.isNotEmpty) return apiBaseUrl;
    const byId = <String, String>{
      'openai': 'https://api.openai.com/v1',
      'anthropic': 'https://api.anthropic.com',
      'google': 'https://generativelanguage.googleapis.com/v1beta',
      'groq': 'https://api.groq.com/openai/v1',
      'mistral': 'https://api.mistral.ai/v1',
      'xai': 'https://api.x.ai/v1',
      'deepseek': 'https://api.deepseek.com',
      'cerebras': 'https://api.cerebras.ai/v1',
    };
    final known = byId[id];
    if (known != null) return known;
    switch (wireProtocol) {
      case AiWireProtocol.ollama:
        return 'http://localhost:11434/v1';
      case AiWireProtocol.anthropic:
      case AiWireProtocol.google:
        // The `byId` map already covers the genuine first-party `anthropic` /
        // `google` ids. A provider that shares the SDK family but is *not* the
        // first-party id (e.g. `google-vertex`) reaches here — its correct
        // endpoint is a regional/Vertex host we don't know, so returning null
        // makes the settings UI prompt for a base URL and lets inference fail
        // closed rather than dialing the first-party host with the wrong key.
        return null;
      case AiWireProtocol.openai:
      case AiWireProtocol.azure:
        // Unknown OpenAI-compatible host or an Azure per-resource endpoint —
        // there is no safe default; the user must configure the base URL.
        return null;
    }
  }

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
