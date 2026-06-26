# NightMail AI Subsystem — Design

**Date:** 2026-06-26
**Status:** Approved (design phase)
**Branch:** `feat/ai-subsystem`

## Summary

Add an AI subsystem to NightMail built around a **rich, auto-updating provider/model
registry** (catalog sourced from [models.dev](https://models.dev), cached offline) with a
small set of lazy wire adapters behind it. Four AI features will eventually run against this
registry — compose/smart-reply, thread summarization, triage/categorization, and semantic
"ask my inbox" search. The first slice proves the whole stack end-to-end with **streaming
compose/smart-reply**.

The design follows NightMail's existing Clean Architecture (4 layers, `get_it` DI,
`fpdart Either<Failure, T>`, `flutter_bloc`) — no new top-level module, no new packages.

## Goals

- A **rich provider/model catalog** (dozens of providers) that is data, not code, and
  auto-updates from models.dev while working fully offline from cache.
- **Few adapters cover many providers** — metadata (catalog) is decoupled from
  instantiation (wire adapter). Adding an OpenAI-protocol provider = zero code.
- Four AI capabilities as ordinary use cases that **query the registry** (single source of
  truth), never hold parallel provider lists.
- **Privacy-aware by construction** — cloud / local / self-hosted clearly tagged,
  per-capability routing, and a conservative default guard on sending mail bodies to cloud.
- Token-by-token **streaming** in compose from the first slice.

## Non-Goals (YAGNI)

- No bundled LLM SDK packages — everything is HTTP (OpenAI/Anthropic/Ollama/Google REST).
- No capability *registry* yet — features are use cases. Promote them to descriptors only
  if/when there are enough to warrant it.
- No agentic/tool-calling loop in the first slice — single-turn generation with streaming.
- No fine-tuning, no local embedding training. Semantic search lands later as its own slice.

## Core Idea — Split Metadata from Instantiation

The lesson shared by hermes-agent, opencode, and oh-my-pi:

- The **catalog** (providers + models + metadata: context window, modalities, pricing) is
  **data** fetched from models.dev.
- The **wire** is a handful of **adapter** classes.
- A provider entry maps to an adapter via a `wireProtocol` field (sealed enum).
- Adding a provider that speaks an existing protocol (e.g. OpenAI-compatible) is a **data**
  change. Adding a genuinely new protocol is **one adapter class**.

This is what yields a "rich registry" without dozens of code paths.

## Architecture & Layout

Fits existing layers — spread across `domain/`, `data/`, `presentation/`. The registry is an
infrastructure concern living in `data/datasources/ai/`; domain reaches it only through
repository abstractions (never bypass layers).

```
domain/
  entities/ai/
    ai_provider.dart        # descriptor: id, name, kind, wireProtocol, baseUrl?, requiresApiKey, source
    ai_model.dart           # id, providerId, contextWindow, modalities, pricing?, capabilities
    ai_capability.dart      # sealed: compose | summarize | triage | search
    ai_request.dart         # messages, model ref, params (temp, maxTokens), stream flag
    ai_response.dart        # full response (text, usage, finishReason)
    ai_chunk.dart           # streaming delta
    ai_message.dart         # role + content
  repositories/
    ai_catalog_repository.dart      # abstract: fetch/cache provider+model catalog
    ai_inference_repository.dart    # abstract: run() + stream() a request
    ai_settings_repository.dart     # abstract: per-capability provider/model/key selection
  usecases/ai/
    compose_reply.dart      # FIRST SLICE — returns Stream of AiChunk
    summarize_thread.dart   # later
    triage_email.dart       # later — extends bayesian_spam_filter path
    ask_inbox.dart          # later — semantic search
    list_ai_providers.dart
    select_ai_model.dart

data/
  models/ai/
    ai_provider_model.dart          # models.dev JSON <-> entity
    ai_model_model.dart
    catalog_response_model.dart
  datasources/ai/
    models_dev_catalog_datasource.dart   # dio fetch from models.dev/api.json
    ai_catalog_cache_datasource.dart     # drift-backed cache; stale-while-revalidate
    ai_provider_registry.dart            # ★ THE REGISTRY (singleton in get_it)
    ai_adapter_factory.dart              # wireProtocol -> adapter (lazy)
    inference/
      ai_adapter.dart                    # ★ normalization boundary (interface)
      openai_compatible_adapter.dart     # OpenAI, self-hosted, Groq, OpenRouter, vLLM, LM Studio…
      anthropic_adapter.dart
      ollama_adapter.dart                # later
      google_adapter.dart                # later
  repositories/
    ai_catalog_repository_impl.dart
    ai_inference_repository_impl.dart
    ai_settings_repository_impl.dart

presentation/
  blocs/ai/
    ai_compose_cubit.dart       # FIRST SLICE — streams tokens into the editor
    ai_settings_cubit.dart
  pages/settings/
    ai_settings_page.dart       # pick provider+model per capability, enter keys
  widgets/
    (compose "AI" button, thread summary panel — later)
```

## The Registry (centerpiece)

`AiProviderRegistry` — a `get_it` singleton, the single source of truth for "what backends
exist and what can they do."

- **Catalog ingestion:** `models_dev_catalog_datasource` fetches `https://models.dev/api.json`
  (~2.4 MB, 144 providers / 5308 models, a JSON object keyed by provider id) via the existing
  `dio` instance. `ai_catalog_cache_datasource` persists it into **drift tables** (see "Schema
  Mapping" below) for queryability — filter by kind/modality/capability in SQL rather than
  loading the whole blob. **Stale-while-revalidate**: serve cache immediately, refresh in the
  background, operate fully offline when the network/catalog is unavailable.
- **Derived fields:** models.dev carries no privacy `kind` and no `wireProtocol`. The mapper
  **derives** both — `kind` from the provider id / `env` / `open_weights` heuristic, and
  `wireProtocol` from the provider's `npm` package (and per-model `provider.shape`). See
  "Schema Mapping" for the rules.
- **Assembly:** `registry.all()` = catalog providers ∪ user BYO providers (OpenAI-compatible
  endpoints stored in `flutter_secure_storage`). Every entry **source-tagged**
  `catalog | user`.
- **Query API:** `all()`, `byId(id)`, `byKind(cloud | local | selfHosted)`,
  `modelsFor(providerId)`, `forCapability(capability)`. Use cases query this; they never keep
  parallel provider lists.
- **Lazy instantiation:** `AiAdapterFactory` resolves a provider's `wireProtocol` to one of
  the adapter classes, only when actually used.
- **Availability metadata** on each entry: `requiresApiKey`, `isAvailable()` (API key present
  / local server reachable), `installHint`. The UI uses this to show "needs API key" or
  "Ollama not running" rather than failing opaquely.

## models.dev Schema Mapping & Drift Cache

Resolved against the live `api.json` (field names below are verbatim from the JSON). Top level
is an **object keyed by provider id**; each provider's `models` is likewise an **object keyed
by model id** (iterate `.entries`; the key is redundant with the nested `id`).

### Provider — JSON → entity / drift `ai_providers` table

| models.dev field | type | entity / column | notes |
|---|---|---|---|
| `id` (= map key) | string | `id` (PK) | |
| `name` | string | `name` | |
| `npm` | string | `npm` | AI-SDK package, e.g. `@ai-sdk/anthropic` — drives `wireProtocol` |
| `doc` | string | `doc` | docs URL |
| `env` | array\<string> | `envJson` (TEXT, JSON) | env var names; **empty ⇒ no key required** |
| `api` | string? | `apiBaseUrl` (nullable) | absent for most first-party hosted providers |
| — derived — | — | `kind` (TEXT enum) | `cloud \| local \| selfHosted`, see rules |
| — derived — | — | `wireProtocol` (TEXT enum) | `openai \| anthropic \| google \| ollama`, see rules |
| — | — | `source` (TEXT enum) | `catalog \| user` |

### Model — JSON → entity / drift `ai_models` table

Composite key `(providerId, id)`; FK `providerId → ai_providers.id`.

**Always present:** `id`, `name`, `attachment` (bool), `reasoning` (bool), `tool_call` (bool),
`open_weights` (bool), `release_date` (TEXT `YYYY-MM-DD`), `last_updated` (TEXT).
`modalities.{input,output}` (array\<string>, enum `text|image|audio|video|pdf`) → flattened to
`inputModalitiesJson` / `outputModalitiesJson` (TEXT, JSON lists).
`limit.context` / `limit.output` (number, always) → `contextLimit` / `outputLimit`;
`limit.input` (number, **optional**) → `inputLimit` (nullable).

**Optional scalars** → nullable columns: `temperature` (bool), `structured_output` (bool),
`family` (string), `status` (string enum `alpha|beta|deprecated`).
`knowledge` (string) → `knowledgeRaw` (TEXT, **do not parse** — granularity varies
`YYYY-MM` vs `YYYY-MM-DD`).

**`cost` (object, optional — absent for free/local models):** flatten scalars to nullable REAL
columns `costInput`, `costOutput`, `costCacheRead`, `costCacheWrite`, `costReasoning`,
`costInputAudio`, `costOutputAudio`. Keep the variable parts as JSON TEXT columns:
`costTiersJson` (`cost.tiers` array), `costOver200kJson` (`cost.context_over_200k` object).

**Variable/polymorphic** → JSON TEXT columns: `reasoningOptionsJson` (`reasoning_options`
array of `{type, min?, max?, values?}`), `experimentalJson` (`experimental`),
`providerOverrideJson` (per-model `provider` `{npm?, api?, shape?}`).
`interleaved` is **polymorphic (bool | `{field}`)** → normalize to nullable `interleavedField`
(TEXT): null when false/absent, the `field` value (e.g. `reasoning_content`) when object.

### Derivation rules

- **`wireProtocol`** from `npm`: `@ai-sdk/anthropic` → `anthropic`; `@ai-sdk/google*` →
  `google`; everything OpenAI-shaped (`@ai-sdk/openai`, `openai-compatible`, most others) →
  `openai`; known local-runtime providers (`ollama`, `lmstudio`, `llama`) → `ollama`. Per-model
  `provider.shape` (`completions|responses`) selects the request variant inside the OpenAI
  adapter. **Unknown `npm` ⇒ default `openai`** (the compatible adapter), and the
  `wireProtocol` sealed `switch` stays exhaustive at compile time.
- **`kind`**: provider id in a known-local set (`ollama`, `lmstudio`, `llama`) → `local`;
  a `user`-source BYO entry pointing at a custom `apiBaseUrl` → `selfHosted`; otherwise →
  `cloud`. (`open_weights` is a *model* flag and is surfaced in the UI, but does not by itself
  make a hosted provider `local`.)
- **`requiresApiKey`** = `env` is non-empty.

### Drift specifics

Two tables (`ai_providers`, `ai_models`) plus a `catalog_meta` row holding `fetchedAt` +
`etag`/`lastModified` for stale-while-revalidate. The drift database already exists in the app
(`drift` / `drift_flutter` deps) — add these tables to the existing schema with a migration,
do not spin up a second database.

## The Normalization Boundary

`AiAdapter` — one interface every provider implements (opencode's `wrap()` lesson):

```dart
abstract class AiAdapter {
  AiWireProtocol get protocol;
  // Single-shot.
  Future<Either<Failure, AiResponse>> run(AiRequest request);
  // Streaming — token-by-token (SSE over dio).
  Stream<Either<Failure, AiChunk>> stream(AiRequest request);
}
```

Every adapter: validates input, maps `AiRequest` to the provider's wire format, parses the
response / SSE stream, and normalizes errors into `AiFailure`. Features never see
provider-specific shapes.

**Streaming** is implemented as Server-Sent-Events over `dio` (`responseType: stream`). No SDK
needed. The cubit consumes the `Stream<Either<Failure, AiChunk>>` and appends deltas into the
compose editor live; a terminal chunk carries `finishReason` + usage.

## Privacy Model (email-specific)

- Provider `kind` (cloud / local / selfHosted) — **derived** by the mapper (models.dev has no
  such field; see "Schema Mapping") — surfaced everywhere a model is chosen. A model's
  `open_weights` flag is shown too, but cloud-hosted open-weights models are still `cloud`.
- **Per-capability routing:** the user may route triage to a local model while compose uses a
  cloud one. Selection is stored per capability in `AiSettingsRepository`.
- **Conservative default guard:** a "don't send mail bodies to cloud providers" setting that
  the use cases honor; defaults to the safe option. Bodies truncated/redacted where the
  feature allows.
- API keys only in `flutter_secure_storage` — never in drift or plaintext.

## Data Flow — Compose / Smart-Reply (first slice)

```
compose dialog
  → AiComposeCubit.generate()
  → ComposeReply usecase  (returns Stream<Either<Failure, AiChunk>>)
  → AiSettingsRepository  (which provider+model+key for `compose`)
  → AiProviderRegistry    (resolve descriptor + availability check)
  → AiInferenceRepository.stream()
  → AiAdapterFactory      (adapter by wireProtocol)
  → adapter.stream()      (SSE over dio)
  → cubit appends deltas live into the editor
  → terminal chunk: finishReason + usage
```

## Error Handling

`fpdart Either<Failure, T>` throughout (existing pattern). New `AiFailure` subtypes:

- `NoProviderConfigured` — no provider/model selected for this capability.
- `MissingApiKey` — provider requires a key, none stored.
- `ProviderUnreachable` — network/local server down.
- `RateLimited` — provider 429.
- `ContextTooLong` — request exceeds model context window (checked against catalog metadata).
- `CatalogUnavailable` — models.dev fetch failed → fall back to cache; surfaced only if no
  cache exists.

## Testing

- **Registry:** merge/precedence/source-tagging; **exhaustive `switch` on the `wireProtocol`
  sealed class** so the build fails if a protocol lacks an adapter (oh-my-pi's compile-time
  exhaustiveness trick, Dart-native via sealed classes).
- **Adapters:** contract tests with mocked `dio` (`mockito`, already a dep), including an SSE
  stream fixture for the streaming path.
- **Catalog:** stale-while-revalidate behavior (cache hit, background refresh, offline).
- **Use cases:** mocked repositories.

## Dependencies

Reuse `dio`, `get_it`, `fpdart`, `flutter_secure_storage`, `drift`, `path_provider`.
**No new packages.** Streaming is SSE over `dio`.

## DI Wiring

Register in `injection_container.dart` alongside existing features:
`AiProviderRegistry` (lazy singleton), the three datasources, `AiAdapterFactory`, the three
repository impls, and the use cases. Cubits registered as factories.

## First Slice — Build Order

1. Catalog datasource + cache + `AiProviderRegistry` (the rich registry).
2. `AiAdapter` interface + `AiAdapterFactory` + OpenAI-compatible adapter + Anthropic adapter
   (both with streaming).
3. `AiSettingsRepository` (pick provider/model + key) + minimal `ai_settings_page.dart`.
4. `ComposeReply` use case + `AiComposeCubit` + compose-dialog "AI" entry point, streaming
   end-to-end.

Then, as follow-on slices against the same registry: summarize → triage (extends
`bayesian_spam_filter`) → semantic search.

## Open Questions / Deferred

- Semantic search indexing strategy (embeddings store) — its own future spec.

**Resolved:** models.dev schema mapping is fixed (see "Schema Mapping"). Catalog cache is
**drift** (queryable), added to the existing app database via migration.
