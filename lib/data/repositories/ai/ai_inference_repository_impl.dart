import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_chunk.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../../domain/entities/ai/ai_request.dart';
import '../../../domain/entities/ai/ai_response.dart';
import '../../../domain/repositories/ai/ai_inference_repository.dart';
import '../../../domain/repositories/ai/ai_settings_repository.dart';
import '../../datasources/ai/ai_adapter_factory.dart';
import '../../datasources/ai/ai_provider_registry.dart';
import '../../datasources/ai/inference/ai_adapter.dart';

/// Resolves a request to a provider descriptor, endpoint, key and wire adapter,
/// then delegates to that adapter.
///
/// The registry is the single source of truth for "what backends exist"; the
/// settings repository supplies the per-provider API key from secure storage;
/// the factory maps the provider's [AiWireProtocol] to a concrete adapter.
/// Missing configuration is normalized into [AiFailure] subtypes
/// ([NoProviderConfigured] / [MissingApiKey]) before any network call.
class AiInferenceRepositoryImpl implements AiInferenceRepository {
  const AiInferenceRepositoryImpl({
    required AiProviderRegistry registry,
    required AiAdapterFactory adapterFactory,
    required AiSettingsRepository settingsRepository,
  })  : _registry = registry,
        _adapterFactory = adapterFactory,
        _settingsRepository = settingsRepository;

  final AiProviderRegistry _registry;
  final AiAdapterFactory _adapterFactory;
  final AiSettingsRepository _settingsRepository;

  @override
  Future<Either<Failure, AiResponse>> run(AiRequest request) async {
    final resolved = await _resolve(request);
    return resolved.fold(
      Left.new,
      // Use the shape-resolved request (r.request), not the caller's, so a
      // model that declares the OpenAI Responses shape is routed correctly.
      (r) => r.adapter.run(
        r.request,
        apiKey: r.apiKey,
        baseUrl: r.baseUrl,
      ),
    );
  }

  @override
  Stream<Either<Failure, AiChunk>> stream(AiRequest request) async* {
    final resolved = await _resolve(request);
    yield* resolved.fold(
      (failure) => Stream<Either<Failure, AiChunk>>.value(Left(failure)),
      // Use the shape-resolved request (r.request) — see run() above.
      (r) => r.adapter.stream(
        r.request,
        apiKey: r.apiKey,
        baseUrl: r.baseUrl,
      ),
    );
  }

  /// Resolves the provider descriptor, endpoint, key and adapter for [request],
  /// or a config [Failure] when the request cannot be served.
  Future<Either<Failure, _ResolvedTarget>> _resolve(AiRequest request) async {
    // The registry is a shared singleton that may have loaded its BYO providers
    // before this one was added (e.g. user adds a provider, then composes).
    // Re-sync the durable config before resolving so a just-added provider is
    // visible here, and cold-load the catalog if inference is the first reader.
    await _registry.ensureReady();
    final provider = _registry.byId(request.providerId);
    if (provider == null) {
      return Left(
        NoProviderConfigured(
          message: 'No provider configured for id "${request.providerId}".',
        ),
      );
    }

    final keyResult = await _settingsRepository.getApiKey(provider.id);
    return keyResult.flatMap((apiKey) {
      // Only pre-empt the call for catalog providers, where models.dev's `env`
      // reliably tells us a key is required. User/BYO endpoints (local Ollama,
      // self-hosted proxies) may need no key at all, so we never hard-block them
      // — we send whatever key is stored (possibly none) and let the server
      // decide; a real 401 still surfaces as MissingApiKey from the adapter.
      final keyRequired = provider.requiresApiKey &&
          provider.source != AiProviderSource.user;
      if (keyRequired && (apiKey == null || apiKey.isEmpty)) {
        return Left(
          MissingApiKey(
            message: 'Provider "${provider.id}" requires an API key, '
                'but none is stored.',
          ),
        );
      }

      // Azure has no fixed endpoint — a per-resource base URL must be supplied
      // at configuration time. Fail closed with a typed config failure rather
      // than dialing a placeholder host that would surface as a confusing DNS
      // error to the user.
      final hasBase =
          provider.apiBaseUrl != null && provider.apiBaseUrl!.isNotEmpty;
      if (provider.wireProtocol == AiWireProtocol.azure && !hasBase) {
        return Left(
          NoProviderConfigured(
            message: 'Provider "${provider.id}" (Azure) requires an explicit '
                'API base URL, but none is configured.',
          ),
        );
      }

      return Right(
        _ResolvedTarget(
          adapter: _adapterFactory.forProtocol(provider.wireProtocol),
          apiKey: apiKey,
          baseUrl: hasBase
              ? provider.apiBaseUrl!
              : _defaultBaseUrl(provider.wireProtocol),
          // Resolve the routed model's wire shape (completions vs responses)
          // from its catalog providerOverride before delegating.
          request: _withResolvedShape(request, provider),
        ),
      );
    });
  }

  /// Returns [request] tagged with the wire shape its routed model declares.
  ///
  /// models.dev exposes a per-model `provider` override that may carry
  /// `shape: 'responses'`, meaning the model speaks the OpenAI Responses API
  /// (`/responses`) rather than Chat Completions. We look the routed model up by
  /// id in the resolved provider and, when it opts into the responses shape,
  /// flip the request accordingly; otherwise the request passes through
  /// unchanged (defaulting to [AiRequestShape.completions]).
  static AiRequest _withResolvedShape(AiRequest request, AiProvider provider) {
    for (final model in provider.models) {
      if (model.id != request.modelId) continue;
      final override = model.providerOverride;
      if (override != null && override['shape'] == 'responses') {
        return request.copyWith(shape: AiRequestShape.responses);
      }
      break;
    }
    return request;
  }

  /// Fallback endpoint when a provider carries no explicit `apiBaseUrl`.
  ///
  /// Azure is intentionally absent — it has no fixed endpoint, so a missing
  /// base URL is rejected in [_resolve] with a typed failure instead.
  static String _defaultBaseUrl(AiWireProtocol protocol) {
    switch (protocol) {
      case AiWireProtocol.openai:
        return 'https://api.openai.com/v1';
      case AiWireProtocol.anthropic:
        // No trailing `/v1`: the Anthropic adapter appends `/v1/messages`, so a
        // `/v1` suffix here would double it into `/v1/v1/messages` (404).
        return 'https://api.anthropic.com';
      case AiWireProtocol.google:
        // Google's native Gemini surface. The Google adapter appends
        // `/models/{modelId}:generateContent` (or `:streamGenerateContent`),
        // so the base is the `/v1beta` root without the `/openai` suffix.
        return 'https://generativelanguage.googleapis.com/v1beta';
      case AiWireProtocol.ollama:
        return 'http://localhost:11434/v1';
      case AiWireProtocol.azure:
        // Unreachable: azure with a missing base URL fails closed in _resolve.
        return 'https://YOUR-RESOURCE.openai.azure.com/openai/v1';
    }
  }
}

/// A fully resolved inference target: the adapter to call plus the credentials
/// and endpoint it needs.
class _ResolvedTarget {
  const _ResolvedTarget({
    required this.adapter,
    required this.apiKey,
    required this.baseUrl,
    required this.request,
  });

  final AiAdapter adapter;
  final String? apiKey;
  final String baseUrl;

  /// The request to delegate, already tagged with its resolved wire shape.
  final AiRequest request;
}
