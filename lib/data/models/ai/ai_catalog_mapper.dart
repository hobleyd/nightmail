import '../../../domain/entities/ai/ai_model.dart';
import '../../../domain/entities/ai/ai_provider.dart';

/// Maps the raw `https://models.dev/api.json` document into in-memory
/// [AiProvider] / [AiModel] entities, per the AI subsystem design spec's
/// "models.dev Schema Mapping".
///
/// The top level of `api.json` is an **object keyed by provider id**; each
/// provider's `models` is likewise an **object keyed by model id** (the key is
/// redundant with the nested `id`). models.dev carries no privacy `kind` and no
/// `wireProtocol`; both are **derived** here (see the derivation helpers).
class AiCatalogMapper {
  const AiCatalogMapper._();

  /// Provider ids whose backends run a local model runtime. Drives the
  /// `local` privacy kind (and, for the chat runtimes, the `ollama` wire
  /// protocol — `laya-mlx` is a System One runtime and keeps its own wire).
  static const Set<String> _localProviderIds = {
    'ollama',
    'lmstudio',
    'llama',
    _layaMlxId,
  };

  /// Parse the full decoded `api.json` object into the catalog's providers,
  /// each carrying its own list of models. All entries are tagged
  /// [AiProviderSource.catalog].
  ///
  /// models.dev has dropped the plain local-runtime `ollama` entry this app
  /// has always assumed exists (it now only lists `ollama-cloud`, Ollama's
  /// paid hosted API, which needs a key and points at `ollama.com`). Without
  /// a synthesized fallback, searching "Ollama" in the catalog surfaces only
  /// that cloud entry, so a user picking it never reaches their local server.
  /// Inject [_localOllamaProvider] whenever upstream doesn't supply one.
  static List<AiProvider> parseCatalog(Map<String, dynamic> json) {
    final providers = <AiProvider>[];
    for (final entry in json.entries) {
      final raw = entry.value;
      if (raw is! Map<String, dynamic>) continue;
      providers.add(_parseProvider(entry.key, raw));
    }
    if (!providers.any((p) => p.id == _localOllamaId)) {
      providers.add(_localOllamaProvider);
    }
    for (final synthesized in _systemOneProviders) {
      if (!providers.any((p) => p.id == synthesized.id)) {
        providers.add(synthesized);
      }
    }
    return providers;
  }

  static const String _localOllamaId = 'ollama';
  static const String _jevId = 'jev';
  static const String _layaMlxId = 'laya-mlx';

  /// System One (typed decision) providers, none of which models.dev lists —
  /// it catalogs text-generation APIs only. Synthesized the same way as the
  /// local Ollama entry so they are discoverable under "From catalog".
  ///
  /// * [_jevProvider] — TypeSafe's hosted Jev API. Keyed; the model list is
  ///   static because the API has no models-listing route.
  /// * [_layaMlxProvider] — the open Laya decision model running on Apple MLX
  ///   behind a Jev-compatible bridge on `127.0.0.1:8766`, provisioned
  ///   outside this repo (laya-mlx itself ships no HTTP server). Keyless and
  ///   local; models are listed live from the bridge's `/v1/models`, so none
  ///   are baked in here.
  static const List<AiProvider> _systemOneProviders = [
    _jevProvider,
    _layaMlxProvider,
  ];

  static const AiProvider _jevProvider = AiProvider(
    id: _jevId,
    name: 'TypeSafe Jev (System One)',
    npm: '@typesafe-ai/sdk',
    doc: 'https://docs.typesafe.ai',
    env: ['TYPESAFE_API_KEY'],
    kind: AiProviderKind.cloud,
    wireProtocol: AiWireProtocol.systemOne,
    source: AiProviderSource.catalog,
    models: [
      AiModel(
        id: 'jev-latest',
        providerId: _jevId,
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
        family: 'jev',
      ),
      AiModel(
        id: 'jev-preview',
        providerId: _jevId,
        name: 'Jev (preview)',
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
        family: 'jev',
        status: AiModelStatus.beta,
      ),
    ],
  );

  static const AiProvider _layaMlxProvider = AiProvider(
    id: _layaMlxId,
    name: 'Laya-MLX (local System One)',
    npm: 'laya-mlx',
    doc: 'https://github.com/mizorewww/laya-mlx',
    env: [],
    kind: AiProviderKind.local,
    wireProtocol: AiWireProtocol.systemOne,
    source: AiProviderSource.catalog,
  );

  /// Synthesized local-Ollama-server descriptor (see [parseCatalog]). Keyless,
  /// with no `apiBaseUrl` — it resolves to `http://localhost:11434/v1` via
  /// [AiProvider.defaultBaseUrl]'s `ollama` wire-protocol fallback, same as a
  /// real catalog entry would.
  static const AiProvider _localOllamaProvider = AiProvider(
    id: _localOllamaId,
    name: 'Ollama (local)',
    npm: 'ollama-ai-provider',
    doc: 'https://ollama.com',
    env: [],
    kind: AiProviderKind.local,
    wireProtocol: AiWireProtocol.ollama,
    source: AiProviderSource.catalog,
  );

  static AiProvider _parseProvider(String providerId, Map<String, dynamic> p) {
    final id = (p['id'] as String?) ?? providerId;
    final npm = (p['npm'] as String?) ?? '';
    final env =
        (p['env'] as List<dynamic>?)?.whereType<String>().toList() ??
            const <String>[];

    final modelsJson = p['models'] as Map<String, dynamic>? ?? const {};
    final models = <AiModel>[];
    for (final m in modelsJson.entries) {
      final raw = m.value;
      if (raw is! Map<String, dynamic>) continue;
      models.add(_parseModel(id, m.key, raw));
    }

    return AiProvider(
      id: id,
      name: (p['name'] as String?) ?? id,
      npm: npm,
      doc: (p['doc'] as String?) ?? '',
      env: env,
      apiBaseUrl: p['api'] as String?,
      kind: _deriveKind(id),
      wireProtocol: _deriveWireProtocol(npm),
      source: AiProviderSource.catalog,
      models: models,
    );
  }

  static AiModel _parseModel(
    String providerId,
    String modelId,
    Map<String, dynamic> m,
  ) {
    final modalities = m['modalities'] as Map<String, dynamic>?;
    final limit = m['limit'] as Map<String, dynamic>?;
    final cost = m['cost'] as Map<String, dynamic>?;

    return AiModel(
      id: (m['id'] as String?) ?? modelId,
      providerId: providerId,
      name: (m['name'] as String?) ?? modelId,
      attachment: m['attachment'] as bool? ?? false,
      reasoning: m['reasoning'] as bool? ?? false,
      toolCall: m['tool_call'] as bool? ?? false,
      openWeights: m['open_weights'] as bool? ?? false,
      releaseDate: (m['release_date'] as String?) ?? '',
      lastUpdated: (m['last_updated'] as String?) ?? '',
      inputModalities:
          (modalities?['input'] as List<dynamic>?)?.whereType<String>().toList() ??
              const <String>[],
      outputModalities:
          (modalities?['output'] as List<dynamic>?)?.whereType<String>().toList() ??
              const <String>[],
      contextLimit: _asInt(limit?['context']) ?? 0,
      outputLimit: _asInt(limit?['output']) ?? 0,
      inputLimit: _asInt(limit?['input']),
      temperature: m['temperature'] as bool?,
      structuredOutput: m['structured_output'] as bool?,
      family: m['family'] as String?,
      status: _parseStatus(m['status']),
      // Granularity varies (YYYY-MM vs YYYY-MM-DD) — kept raw, never parsed.
      knowledgeRaw: m['knowledge'] as String?,
      // Cost map is optional (absent for free/local models); individual tiers are
      // pulled out, with the variable `tiers` array and `context_over_200k`
      // object kept as-is.
      costInput: _asDouble(cost?['input']),
      costOutput: _asDouble(cost?['output']),
      costCacheRead: _asDouble(cost?['cache_read']),
      costCacheWrite: _asDouble(cost?['cache_write']),
      costReasoning: _asDouble(cost?['reasoning']),
      costInputAudio: _asDouble(cost?['input_audio']),
      costOutputAudio: _asDouble(cost?['output_audio']),
      costTiers: cost?['tiers'] as List<dynamic>?,
      costOver200k: cost?['context_over_200k'] as Map<String, dynamic>?,
      reasoningOptions: m['reasoning_options'] as List<dynamic>?,
      experimental: m['experimental'] as Map<String, dynamic>?,
      // Per-model `{npm?, api?, shape?}` override.
      providerOverride: m['provider'] as Map<String, dynamic>?,
      // `interleaved` is polymorphic (bool | {field}); normalize to the nullable
      // `field` value (e.g. `reasoning_content`), null when false/absent.
      interleavedField: _interleavedField(m['interleaved']),
    );
  }

  /// `wireProtocol` from the provider's AI-SDK `npm` package:
  /// `@ai-sdk/anthropic` → anthropic; `@ai-sdk/google*` → google; the System
  /// One SDKs (`typesafe`/`jev`/`laya`) → systemOne; known local-runtime
  /// packages (`ollama`/`lmstudio`/`llama`) → ollama; everything else
  /// (OpenAI-shaped, and **unknown ⇒ default**) → openai.
  static AiWireProtocol _deriveWireProtocol(String npm) {
    final pkg = npm.toLowerCase();
    if (pkg.startsWith('@ai-sdk/anthropic')) return AiWireProtocol.anthropic;
    if (pkg.startsWith('@ai-sdk/google')) return AiWireProtocol.google;
    if (pkg.contains('azure')) return AiWireProtocol.azure;
    // Checked before the local-runtime packages: `laya` must not be mistaken
    // for a chat runtime should models.dev ever list these.
    if (pkg.contains('typesafe') ||
        pkg.contains('jev') ||
        pkg.contains('laya')) {
      return AiWireProtocol.systemOne;
    }
    if (pkg.contains('ollama') ||
        pkg.contains('lmstudio') ||
        pkg.contains('llama')) {
      return AiWireProtocol.ollama;
    }
    return AiWireProtocol.openai;
  }

  /// `kind` from the provider id: a known local-runtime id (`ollama`,
  /// `lmstudio`, `llama`, `laya-mlx`) → local; otherwise → cloud.
  /// (`selfHosted` only ever applies to user-source BYO entries, never to
  /// catalog providers.)
  static AiProviderKind _deriveKind(String providerId) {
    return _localProviderIds.contains(providerId.toLowerCase())
        ? AiProviderKind.local
        : AiProviderKind.cloud;
  }

  static String? _interleavedField(dynamic value) {
    if (value is Map) return value['field'] as String?;
    return null;
  }

  /// Maps the models.dev `status` string (`alpha|beta|deprecated`) onto the
  /// [AiModelStatus] enum; unknown/absent values map to null (stable).
  static AiModelStatus? _parseStatus(dynamic value) {
    if (value is! String) return null;
    switch (value) {
      case 'alpha':
        return AiModelStatus.alpha;
      case 'beta':
        return AiModelStatus.beta;
      case 'deprecated':
        return AiModelStatus.deprecated;
      default:
        return null;
    }
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
