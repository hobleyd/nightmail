# AI Follow-up Review — Native Gemini Adapter + Provider-Aware Endpoints

**Scope:** `git diff origin/main..HEAD` on `feat/ai-subsystem` — new `GoogleAdapter` (native Gemini wire), provider-aware `defaultBaseUrl`, repo fail-closed resolution, settings-page Base-URL gating, DI + tests.

## Verdict

**Merge-ready — no blockers.** No high/critical findings. Nothing crashes, corrupts data, or breaks the happy path. Two **medium** issues are worth fixing before merge (or as an immediate fast-follow): both are error-classification / endpoint-routing correctness gaps that misdirect the user, not functional failures. Everything else is low-severity polish and additive test coverage.

**Counts (post-dedupe):** 0 critical · 0 high · 2 medium · 15 low

---

## Medium

### 1. All HTTP 400s map to `MissingApiKey`, masking `ContextTooLong` and mislabeling malformed requests
- **File:** `lib/data/datasources/ai/inference/google_adapter.dart:373`
- **Why:** `_mapDioError` treats `400 || 401 || 403` all as a key problem and returns `MissingApiKey('Gemini rejected the API key (HTTP $status)...')`. Gemini's native `generateContent` returns **400 INVALID_ARGUMENT** for context overflow (its overflow signal is a 400, not 413/429) and for any malformed body. The parsed error text (`detail`, line 362) is logged but never used to classify. Both siblings diverge: `openai_compatible_adapter.dart:537-542` routes a context-overflow 400 to `ContextTooLong` (never treats 400 as a key error); `anthropic_adapter.dart:320-334` keeps only 401/403 as `MissingApiKey` and maps 400 to `ContextTooLong`/`ServerFailure`. Result: a user who pastes too-long an email is told to rotate a working API key. (`ContextTooLong` already exists in `failures.dart:57`.) *(Consolidates two reports of the same defect — error-mapping and adapter-pattern-fit dimensions.)*
- **Fix:** Before the blanket 400 branch, add a context-overflow heuristic on `detail` (mirror `_looksLikeContextOverflow` / Anthropic's 400 branch — match "token count", "exceeds the maximum", "input token") → `ContextTooLong`. Keep 401/403 as `MissingApiKey`; only treat 400 as a key error when the message mentions "API key not valid"; otherwise fall through to a generic bad-request failure. Update `google_adapter_test.dart:243` accordingly.

### 2. `anthropic`/`google` protocol-fallback arms hide the Base-URL field and misroute SDK-family providers (e.g. `google-vertex`) to the first-party host
- **File:** `lib/domain/entities/ai/ai_provider.dart:103-115`
- **Why:** `defaultBaseUrl` checks the `byId` map (which already contains the genuine first-party `anthropic`/`google` ids) **before** the `wireProtocol` fallback, so the protocol arms (104-107) only ever fire for providers that share the AI-SDK family but are **not** the first-party id — exactly where the first-party host is wrong. `ai_catalog_mapper.dart:124` maps any `@ai-sdk/google*` npm to `AiWireProtocol.google`, so a models.dev entry like `google-vertex` (no `api` URL) gets a non-null `defaultBaseUrl` of `https://generativelanguage.googleapis.com/v1beta`. Two consequences: (1) the settings dialog hides the Base-URL field (`ai_settings_page.dart:938,1097` gate on `defaultBaseUrl == null`), so the user cannot enter the correct regional/Vertex endpoint; (2) inference dials the wrong host with `x-goog-api-key` instead of failing closed. This is also a **regression** vs the old UI, which keyed the field on `apiBaseUrl == null || empty` and would have exposed an editable field.
- **Fix:** Make the `anthropic` and `google` fallback arms return `null` (like `openai`/`azure`). The `byId` map already covers the real first-party ids, so returning null lets the dialog prompt for a Base URL and lets inference fail closed (`NoProviderConfigured`).

---

## Low

### Adapter behaviour / robustness
- **Streaming path has no in-stream `error`-event detection** — `google_adapter.dart:172`. The SSE loop reads only `candidates`/`usageMetadata`; a mid-stream `data: {"error":{...}}` (e.g. RESOURCE_EXHAUSTED) decodes fine, matches nothing, is skipped, and the loop falls through to the unconditional synthetic `done` chunk (207-215) — a truncated generation reported as clean success. Siblings handle this (`anthropic_adapter.dart:205-208`, `openai_compatible_adapter.dart:443`). *Fix:* inside the loop check `json['error']`, `yield Left(...)` mapping `error.code` (429→RateLimited, etc.) and `return`. (Bounded impact — most quota/auth errors arrive as the initial HTTP status, already handled.)
- **`promptFeedback.blockReason` ignored** — `google_adapter.dart:66`. A fully-blocked prompt has no `candidates`, only `{"promptFeedback":{"blockReason":"SAFETY"}}`; `run()` returns `Right(AiResponse(text:'', finishReason:null))` and the stream yields a `done` with null finishReason — a silent empty success, block reason discarded. *Fix:* when `candidates` is empty, surface `promptFeedback.blockReason` as a non-null finishReason or a typed failure.
- **Endpoint assumes a bare `modelId`** — `google_adapter.dart:232`. `'$base/models/$modelId:$method'` doubles to `.../models/models/...` (404) if a `models/`-prefixed id is supplied (Gemini's native resource form; reachable via the free-form model-id field / BYO `/models` listing). *Fix:* strip a leading `models/` and slash before interpolating.
- **Missing up-front `apiKey` guard** — `google_adapter.dart:45`. Gemini always needs a key; Anthropic short-circuits with `MissingApiKey` before any network call (`anthropic_adapter.dart:50-54`), Google sends a keyless request and depends on the 400/403 (then mislabeled per #1). *Fix:* add an early null/empty key check in `run()`/`stream()`. (Repo already pre-empts for catalog providers, so only reachable for a keyless BYO Google provider — cost is a wasted round-trip.)
- **Non-const constructor** — `google_adapter.dart:33`. Both siblings declare `const` over a single `final Dio` field; Google omits it. Cosmetic. *Fix:* `const GoogleAdapter(...)`.

### Endpoints / layering / docs
- **Stale factory comment** — `ai_adapter_factory.dart:44-45` references the removed `_defaultBaseUrl(google)` helper; resolution now goes through `provider.defaultBaseUrl`. *(Two reports merged.)* *Fix:* point the comment at `AiInferenceRepositoryImpl` / `AiProvider.defaultBaseUrl`.
- **Vendor endpoint URLs on the domain entity** — `ai_provider.dart:89`. Concrete hosts now live in `domain/entities` (previously the data-layer repo). Mild placement smell; the entity already carries comparable metadata (`doc`, `npm`, `env`, `apiBaseUrl`), so defensible. *Fix (optional):* relocate the table to a data-layer resolver, or document as a deliberate exception.
- **Gemini base URL triplicated** — `ai_provider.dart:94`. `https://generativelanguage.googleapis.com/v1beta` appears in `byId['google']`, the protocol switch (`:107`), and `GoogleAdapter._defaultBaseUrl` (`:38`); Anthropic duplicated twice. A `v1beta→v1` bump risks drift. *Fix:* one shared const — or drop the now-dead adapter fallback (the repo always passes a non-empty resolved baseUrl).

### Test coverage (additive — code under test is currently correct)
- **Multibyte SSE split across byte chunks untested** — `google_adapter_test.dart:317`. The stateful `utf8.decoder + LineSplitter` (`google_adapter.dart:149-152`) exists to carry a code point across chunk boundaries; the `sse()` helper delivers every event as one whole chunk, so a per-chunk re-decode regression would pass. Anthropic has the dedicated emoji-split test (`anthropic_adapter_test.dart:436`). *Fix:* add a split-emoji stream test.
- **Stream-end with no `finishReason` untested** — `google_adapter_test.dart:319`. Both stream tests send `finishReason:"STOP"`; the no-sentinel case the synthetic terminal chunk exists to normalize (null finishReason) is unasserted. *Fix:* a delta-only stream asserting one `done:true`, `delta:''`, `finishReason==null`.
- **`AiProvider.defaultBaseUrl` has no direct test** — `ai_provider.dart:89`. The `byId` table (groq/mistral/xai/deepseek/cerebras/openai) is entirely uncovered; only anthropic/azure/unknown-openai are touched indirectly. A URL typo would ship. *Fix:* unit test covering apiBaseUrl-wins, each `byId` endpoint, ollama fallback, openai/azure→null.
- **Inference repo never tests Google default-URL resolution** — `ai_inference_repository_impl_test.dart:290`. The headline `.../v1beta` resolution is unasserted end-to-end (anthropic-default is). *Fix:* add a google repo test asserting delegation with `https://generativelanguage.googleapis.com/v1beta`.
- **Error-mapping test omits 401/403/5xx** — `google_adapter_test.dart:243`. Only 400 and 429 asserted; 403 (Gemini's documented bad-key code), 401, and the 5xx→`ProviderUnreachable` catch-all are untested. *Fix:* parametrize the status→failure mapping.
- **`run` unexpected-shape + mid-stream catch untested** — `google_adapter_test.dart:60`. The non-Map `ProviderUnreachable('unexpected response shape')` branch (`58-64`) and the in-loop DioException catch (`191-201`) are never hit. *Fix:* a non-Map `run` test and a delta-then-error mid-stream test.
- **Settings-page Base-URL gating untested** — `ai_settings_page.dart:938`. No test file exists under `test/presentation/pages/settings`; the user-visible `needsUrl = defaultBaseUrl == null` branch is unverified. *Fix:* widget test (or extract `needsUrl` into a pure function) asserting hidden for google/openai, shown for azure/unknown-openai.

---

## What's solid

- **Adapter shape matches the established conventions:** stateful `utf8.decoder + LineSplitter` for SSE reframing, `systemInstruction` + user/model `contents`, `x-goog-api-key` auth, synthetic terminal chunk to normalize Gemini's missing sentinel, and usage-metadata extraction — all consistent with the Anthropic/OpenAI adapters.
- **Fail-closed endpoint resolution is the right call:** the repo now resolves via `provider.defaultBaseUrl` and returns `NoProviderConfigured` when none, instead of silently inventing a host. The settings dialog only prompts for a Base URL when genuinely needed.
- **Factory routing is correct:** google → dedicated adapter, ollama deliberately OpenAI-compatible, covered by `ai_adapter_factory_test.dart`.
- **The new adapter's tests cover the core happy paths and the common error statuses (400/429), DI registration is in place, and the transport-level failures (`ProviderUnreachable`, `RateLimited`, key errors) are correctly classified for the dominant cases.**

The two medium items are narrow, well-localized, and each has a one-to-three-line fix that restores parity with the sibling adapters.
