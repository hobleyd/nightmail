import '../../../domain/entities/ai/ai_provider.dart';
import 'inference/ai_adapter.dart';

/// Resolves an [AiWireProtocol] to the concrete [AiAdapter] that speaks it.
///
/// The two real adapters (OpenAI-compatible and Anthropic) are injected and
/// reused — they are stateless with respect to credentials, which are supplied
/// per call. The switch over [AiWireProtocol] is exhaustive, so the compiler
/// fails the build if a protocol is added without an adapter.
///
/// `google` is a first-class OpenAI-compatible target (its `.../v1beta/openai`
/// surface speaks the OpenAI wire shape), so it reuses the OpenAI adapter
/// directly. `ollama` remains an OpenAI-compatible stand-in. Both keep explicit
/// cases so the exhaustiveness check still flags any new protocol.
class AiAdapterFactory {
  const AiAdapterFactory({
    required AiAdapter openAiAdapter,
    required AiAdapter anthropicAdapter,
    required AiAdapter azureAdapter,
  })  : _openAiAdapter = openAiAdapter,
        _anthropicAdapter = anthropicAdapter,
        _azureAdapter = azureAdapter;

  final AiAdapter _openAiAdapter;
  final AiAdapter _anthropicAdapter;
  final AiAdapter _azureAdapter;

  /// Returns the adapter for [protocol].
  AiAdapter forProtocol(AiWireProtocol protocol) {
    switch (protocol) {
      case AiWireProtocol.openai:
        return _openAiAdapter;
      case AiWireProtocol.anthropic:
        return _anthropicAdapter;
      case AiWireProtocol.azure:
        // OpenAI wire shape, but authenticated with the `api-key` header.
        return _azureAdapter;
      case AiWireProtocol.google:
        // Google speaks the OpenAI-compatible protocol at its
        // `.../v1beta/openai` surface, so the OpenAI adapter handles it as-is.
        // The corrected default base URL is supplied by the inference repo
        // (`_defaultBaseUrl(google)` → `.../v1beta/openai`); no dedicated
        // adapter is needed.
        return _openAiAdapter;
      case AiWireProtocol.ollama:
        // TODO(ai): dedicated Ollama adapter — OpenAI-compatible stand-in.
        return _openAiAdapter;
    }
  }
}
