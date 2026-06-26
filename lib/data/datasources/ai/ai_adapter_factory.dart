import '../../../domain/entities/ai/ai_provider.dart';
import 'inference/ai_adapter.dart';

/// Resolves an [AiWireProtocol] to the concrete [AiAdapter] that speaks it.
///
/// The real adapters (OpenAI-compatible, Anthropic, and native Google Gemini)
/// are injected and reused — they are stateless with respect to credentials,
/// which are supplied per call. The switch over [AiWireProtocol] is exhaustive,
/// so the compiler fails the build if a protocol is added without an adapter.
///
/// `google` speaks Google's native Gemini `generateContent` API via its own
/// dedicated adapter. `ollama` remains an OpenAI-compatible stand-in; it keeps
/// an explicit case so the exhaustiveness check still flags any new protocol.
class AiAdapterFactory {
  const AiAdapterFactory({
    required AiAdapter openAiAdapter,
    required AiAdapter anthropicAdapter,
    required AiAdapter azureAdapter,
    required AiAdapter googleAdapter,
  })  : _openAiAdapter = openAiAdapter,
        _anthropicAdapter = anthropicAdapter,
        _azureAdapter = azureAdapter,
        _googleAdapter = googleAdapter;

  final AiAdapter _openAiAdapter;
  final AiAdapter _anthropicAdapter;
  final AiAdapter _azureAdapter;
  final AiAdapter _googleAdapter;

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
        // Google speaks its native Gemini `generateContent` API, handled by a
        // dedicated adapter. The default base URL is supplied by the inference
        // repo (`_defaultBaseUrl(google)` → `.../v1beta`).
        return _googleAdapter;
      case AiWireProtocol.ollama:
        // TODO(ai): dedicated Ollama adapter — OpenAI-compatible stand-in.
        return _openAiAdapter;
    }
  }
}
