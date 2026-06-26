# NightMail AI Subsystem — Review Report

**Branch:** `feat/ai-subsystem` (working tree, mostly uncommitted)
**Spec:** `docs/superpowers/specs/2026-06-26-ai-subsystem-design.md`
**Date:** 2026-06-26
**Scope:** AI entities/repos/usecases, data adapters/datasources/registry, AI blocs + settings page, and the compose/editor streaming bridge. Findings below are adversarially verified against the real code; severities are the verifier's adjusted values, deduped across review dimensions.

---

## Verdict

The branch is **architecturally sound and Clean-Architecture-faithful**, but it is **not merge-ready as-is**. The layering, DI wiring, failure model, drift migration, and streaming design all follow the repo's established conventions, and the catalog/registry/adapter design is well-decomposed. However, there are **3 high-severity issues** that must be addressed before merge:

1. **Privacy guard is dead end-to-end** — the spec's "don't send mail bodies to cloud providers" safe-default guard is implemented in storage but never read, never enforced, and never surfaced in the UI. A cloud-routed compose silently sends the user's quoted email body to a third-party LLM even at the safe default. (Highest-signal issue.)
2. **First-party Anthropic compose is broken** — the default Anthropic base URL produces a doubled `/v1/v1/messages` path that 404s on every default/first-party Anthropic route.
3. **The riskiest pure logic (catalog mapper kind/wireProtocol derivation) has zero tests** — a regression in provider→adapter routing or cloud/local privacy classification would pass the entire suite.

The medium-severity set is dominated by **test-coverage gaps** (settings repo, cubits, the compose→editor bridge, Azure auth header, OpenAI request construction) plus two real runtime robustness gaps (no Dio timeouts; streaming tokens lost if the webview is not yet ready). The long low-severity tail is mostly stale doc comments, dead code, and pattern-fit nits — none block merge but several are quick wins.

**Counts (deduped):** High 3 · Medium 7 · Low 22 · Total 32.

**Must-change before merge:** H1, H2, H3 (below), plus wiring a settings toggle for the privacy flag (part of H2).

---

## High Severity

### H1 — Privacy "cloud bodies" guard is implemented but never enforced (dead end-to-end)
- **Where:** `lib/domain/usecases/ai/compose_reply.dart:81-97` (consumer gap); flag defined in `lib/data/repositories/ai_settings_repository_impl.dart:151-159` and `lib/domain/repositories/ai_settings_repository.dart:61-64`.
- **Why it matters:** Spec lines 268-270 require the use cases to honor a conservative default guard (`ai_allow_cloud_for_bodies`, default `false`=safe) before sending mail bodies to a cloud provider. `ComposeReply.call()` embeds the stripped original email body into the user prompt unconditionally — no `AiProviderKind` check, no read of `getAllowCloudForBodies()`. A repo-wide grep confirms `getAllowCloudForBodies`/`setAllowCloudForBodies` have **zero callers** outside the storage impl/interface (and test mocks): no usecase reads it, no UI writes it (the 1497-LOC settings page has no toggle). Net effect: a cloud-routed compose transmits the quoted body even with the safe default set — exactly what the guard exists to prevent. This is runtime-observable exfiltration relative to the documented privacy default. (Confirmed across four independent findings spanning correctness, privacy, runtime, and consistency dimensions — merged here.)
- **Fix:** In `ComposeReply` (and any future cloud-bound usecase), resolve the routed provider's kind via the registry and, when `kind == cloud && getAllowCloudForBodies() == false`, omit/redact `originalMessage` (or fail closed with a typed failure). Wire a toggle in `ai_settings_page.dart` → `AiSettingsCubit` → `setAllowCloudForBodies` so the safe default is reachable and overridable. Add a unit test asserting the body is dropped for a cloud route at the default and retained for local/self-hosted or opt-in. (See M5 — the existing happy-path test currently pins the leaking behavior and must be rewritten as part of this fix.)

### H2 — Anthropic default base URL doubles `/v1` → 404 on every first-party Anthropic compose
- **Where:** `lib/data/repositories/ai_inference_repository_impl.dart:111` (`_defaultBaseUrl(anthropic)` returns `https://api.anthropic.com/v1`); `lib/data/datasources/ai/inference/anthropic_adapter.dart:212` (`return '$base/v1/messages';`).
- **Why it matters:** When an Anthropic provider has no explicit `apiBaseUrl` (the spec states models.dev's `api` field is absent for first-party hosted providers, so the catalog Anthropic entry has `apiBaseUrl == null`), `_resolve` supplies the `/v1`-suffixed default and the adapter appends `/v1/messages`, yielding `https://api.anthropic.com/v1/v1/messages` — a 404 on the live default path. The adapter's own default (`https://api.anthropic.com`, no `/v1`) is correct but unreachable because the inference repo always supplies a non-empty base. By contrast the OpenAI default (`.../v1` + `/chat/completions`) is correct, so the trailing `/v1` on the Anthropic default is the genuine anomaly. Untested: the adapter test hardcodes a base without `/v1`, and the inference-repo test only uses explicit `apiBaseUrl`.
- **Fix:** Make the inference repo's anthropic default `https://api.anthropic.com` (no `/v1`), OR have the adapter strip a trailing `/v1` before appending. Add an inference-repo test resolving an anthropic provider with `null apiBaseUrl` and asserting the final URL is `.../v1/messages` exactly once.

### H3 — Catalog mapper derivation (kind / wireProtocol / model parsing) has zero tests
- **Where:** `lib/data/models/ai/ai_catalog_mapper.dart:121` (`_deriveWireProtocol`), `:137` (`_deriveKind`), `:17` (`_localProviderIds`).
- **Why it matters:** `AiCatalogMapper` is the riskiest pure logic in the slice — it derives the privacy `kind` (cloud/local) and `wireProtocol` (which selects the adapter) from raw models.dev JSON and unpacks ~20 per-model fields. Nothing under `test/` imports or exercises it. It even adds an undocumented `if (pkg.contains('azure')) return AiWireProtocol.azure;` branch plus `lmstudio`/`llama` local handling — all unverified. Registry tests hand-build `AiProvider` fixtures with `wireProtocol` hardcoded, bypassing the mapper entirely. A regression (routing Anthropic through the OpenAI adapter, or mis-tagging a cloud provider as local and skipping the privacy guard) would pass the whole suite. The logic is live: `models_dev_catalog_datasource.dart` calls `AiCatalogMapper.parseCatalog` and is DI-registered.
- **Fix:** Add a focused unit test feeding a representative `api.json` fragment: assert `anthropic→anthropic`, `@ai-sdk/google→google`, `azure npm→azure`, `ollama/lmstudio→local+ollama`, unknown npm→`cloud+openai`, plus a couple of model-field round-trips (limit/cost/status/interleaved).

---

## Medium Severity

### M1 — Anthropic SSE decodes UTF-8 per network chunk; multibyte characters split across packets are corrupted
- **Where:** `lib/data/datasources/ai/inference/anthropic_adapter.dart:139` (`carry += utf8.decode(bytes, allowMalformed: true);`).
- **Why it matters:** `allowMalformed: true` replaces incomplete trailing UTF-8 sequences with U+FFFD instead of buffering them; `carry` only stitches partial *lines*, not partial *byte sequences*. Any multibyte codepoint (accented Latin, CJK, emoji) straddling a dio/TCP chunk boundary is permanently mojibake'd. The OpenAI adapter does this correctly via `body.stream.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())` (`openai_compatible_adapter.dart:182-185`). Intermittent and non-fatal (mostly-ASCII email limits impact), but real user-visible corruption.
- **Fix:** Pipe the Anthropic byte stream through `utf8.decoder` (as OpenAI does), or feed bytes into a single long-lived `Utf8Decoder` so partial code points carry across chunks. Add a streaming test splitting a multibyte char across two byte lists.

### M2 — Shared Dio has no timeouts; first-launch catalog fetch and live `/models` lookups can hang forever
- **Where:** `lib/injection_container.dart:322` (`sl.registerLazySingleton<Dio>(() => Dio());` — no `BaseOptions`).
- **Why it matters:** Default Dio has all timeouts null. This single instance backs the catalog datasource, provider-models datasource, and both adapters. On a true first launch (no `CatalogCache` row) with a slow/captive-portal network, `registry.load()` takes the cold branch and `await`s `dio.get('https://models.dev/api.json')` (~2.4MB) with no timeout — AI Settings hangs on a spinner with no error, and the first cold compose hits the same blocking fetch. Ironically the catalog datasource already has `connectionTimeout`/`receiveTimeout`/`sendTimeout` handling that can never fire. After one success a cache blob exists and later loads are background/non-blocking, so only first run + forced refresh are exposed.
- **Fix:** Register Dio with explicit `BaseOptions(connectTimeout: 10s, receiveTimeout: 30s)` so hangs surface as `DioException → NetworkException/ProviderUnreachable`. Use a longer/no `receiveTimeout` only on streaming inference via per-call `Options`.

### M3 — Streaming AI tokens permanently lost if the webview editor isn't ready (no recovery on Done)
- **Where:** `lib/presentation/widgets/compose_dialog.dart:680-685`; `lib/presentation/widgets/html_email_editor.dart:92-96`.
- **Why it matters:** `_insertAiDelta` advances `_aiInsertedLen = text.length` unconditionally, then fires `insertAtCursor(delta)` (fire-and-forget `_controller?.evaluateJavascript('insertAtSaved(...)')`). When compose starts in plain-text mode, `_onAiCompose` calls `_switchToHtml()` which mounts a **fresh** InAppWebView concurrently with generation; opening deltas can arrive before `onWebViewCreated` sets `_controller` (dropped by `?.`) or before `editor.html` loads (JS no-op), and `onLoadStop`'s `setContent` can overwrite early inserts. Because the counter already advanced, the terminal `AiComposeDone` re-call short-circuits on `if (text.length <= _aiInsertedLen) return;` and cannot recover the lost prefix. Result: a plain-text reply → AI compose loses the beginning of the draft with no error shown.
- **Fix:** Only advance `_aiInsertedLen` after a successful insert, or gate `insertAtCursor` on editor readiness (`onLoadStop`) and queue deltas; alternatively have the `AiComposeDone` branch reconcile the full accumulated text against the editor's current content rather than trusting `_aiInsertedLen`.

### M4 — `AiSettingsRepositoryImpl` is untested, including the safe-default of the privacy flag
- **Where:** `lib/data/repositories/ai_settings_repository_impl.dart:151-159` (and the 213-LOC file overall). No `test/` file references it.
- **Why it matters:** API-key storage, routing CRUD, and the privacy guard are uncovered. The guard's safe default (`false` when key absent) is the foundation of the privacy story, but nothing pins `getAllowCloudForBodies()` → `Right(false)` on absent key, nor the `'true'`/`'false'` stringified round-trip. The current code is correct, so this is a coverage gap on correct code (hence medium, not high), but a parsing regression (treating any non-null as true) would silently flip the default to the unsafe option with no test to catch it.
- **Fix:** Repo test with a mocked `FlutterSecureStorage`: absent key → `Right(false)`; `'true'`/`'false'` round-trip; `getApiKey`/`setApiKey`/`deleteApiKey`; routing persistence; and Failure mapping on storage exceptions.

### M5 — `compose_reply` happy-path test codifies the privacy-leaking behavior as the expected contract
- **Where:** `test/domain/usecases/ai/compose_reply_test.dart:77-78` (`expect(userTurn.content, contains('Are you coming to the meeting?'))`).
- **Why it matters:** The test asserts the quoted original body is embedded verbatim in the prompt — pinning the H1 leak as "correct." This gives false confidence and would actively block a future body-stripping fix unless rewritten. (A test-quality finding tied to H1; severity medium to avoid double-counting the production leak.)
- **Fix:** Add a test asserting that with the guard at its safe default and a cloud route, the body is NOT sent (instruction-only); reserve the "contains original" assertion for the `allow=true` / local-provider case — forcing the guard to be wired before the test passes.

### M6 — OpenAI request construction and the Azure `api-key` header branch are unverified
- **Where:** `test/data/datasources/ai/inference/openai_compatible_adapter_test.dart` (constructs with default `useApiKeyHeader=false`, no request capture); Azure branch at `lib/data/datasources/ai/inference/openai_compatible_adapter.dart:55`.
- **Why it matters:** Unlike the Anthropic test (which captures and asserts path/headers/body), the OpenAI tests only inspect the parsed result — never asserting endpoint, `Authorization: Bearer`, `stream:true`, or `stream_options.include_usage`. The Azure variant `OpenAiCompatibleAdapter(useApiKeyHeader:true)` (registered as `azureAdapter` in DI), which sends `api-key` instead of `Authorization`, has **no** test exercising that header branch; the factory test only proves azure maps to a distinct mock. Azure auth can break with the suite green.
- **Fix:** Add capture-based assertions on the OpenAI request (endpoint, Bearer header, stream_options) and a dedicated test constructing `OpenAiCompatibleAdapter(useApiKeyHeader:true)` verifying `api-key` is sent and `Authorization` is absent.

### M7 — Cubits and the compose→editor streaming-insert bridge have no tests
- **Where:** `lib/presentation/blocs/ai/ai_compose_cubit.dart`, `ai_settings_cubit.dart`, and the delta-insert logic in `compose_dialog.dart:681-684`.
- **Why it matters:** `AiComposeCubit`, `AiSettingsCubit`, and the cumulative-text diff against `_aiInsertedLen` plus the cubit's `onDone` safety-net emit are entirely untested. The fragile streaming UX (duplicate text, lost final delta, caret drift, the `savedRange` selection bridge in `editor.html`) is unguarded.
- **Fix:** `bloc_test` coverage for both cubits (state transitions, `isClosed` guards, subscription cancellation on `close()`, `onDone`-vs-terminal-chunk dedup), and at minimum a unit test for the delta-diff insert computation.

---

## Low Severity

| # | Title | File:line | Why it matters | Suggested fix |
|---|-------|-----------|----------------|---------------|
| L1 | Domain `AiModel` leaks raw/untyped JSON (`dynamic`, `Map<String,dynamic>`, `List<dynamic>`) into the domain layer | `lib/domain/entities/ai/ai_model.dart:128-149` | Provider wire shape bleeds across data→domain; these fields are in Equatable `props`, so equality depends on decoded-JSON structures. Intentional/documented, no runtime impact. | Model as typed value objects, or keep raw JSON in a data-layer model; at minimum use `Object?` over `dynamic`. |
| L2 | Inference adapters return `Either<Failure>` from the datasource layer (inverts datasource-throws / repo-converts) | `lib/data/datasources/ai/inference/ai_adapter.dart:28-42` | Internally inconsistent with the AI catalog datasources, which throw. Streaming forces Either; single-shot `run` could have followed throw/convert. Already documented on `AiAdapter`. | Document the intentional adapter-returns-Either contract, or move single-shot conversion into the repo. Pick one convention. |
| L3 | `ProviderModelsDatasourceImpl` lets raw `DioException` escape | `lib/data/datasources/ai/provider_models_datasource.dart:57-61` | Sibling `ModelsDevCatalogDatasourceImpl` maps to `NetworkException/ServerException`; only saved by a broad `catch (e)` in the repo. Benign but inconsistent. | Wrap `_dio.get` in a `DioException` handler that throws core exceptions. |
| L4 | Conditional/etag refresh half-built: registry doc + `CatalogCache` columns describe a 304 stale-while-revalidate flow the code never performs | `lib/data/datasources/ai/ai_provider_registry.dart:40-59`; `lib/data/database/app_database.dart:97` | Doc claims a `fetch({etag,lastModified}) → CatalogFetchResult.notModified` contract and `getUserProviders()` merge source; real interface is `fetchRaw()`/`parse()` + `getConfiguredProviders()`, `_doRefresh` fetches unconditionally, etag/lastModified columns stay null. Dead schema + stale docs (no runtime effect). | Rewrite the contracts block + table doc to match shipped interfaces, or implement conditional fetch (send `If-None-Match`/`If-Modified-Since`, handle 304, persist response values). |
| L5 | Streaming repository interface (`Stream<Either<Failure, AiChunk>>`) is a new pattern with no precedent | `lib/domain/repositories/ai_inference_repository.dart:22` | No other repo returns a `Stream`; defensible but worth noting for consistency. | Note the streaming-repo convention in `CLAUDE.md` so future repos follow the same shape. |
| L6 | `ProviderModelsDatasourceImpl` is `const` with a `prefer_initializing_formals` ignore, unlike sibling datasources | `lib/data/datasources/ai/provider_models_datasource.dart:24` | Lone `const`+ignore is noise vs the surrounding `({required Dio dio}) : _dio = dio;` form. | Drop the `const` and the lint-ignore comment. |
| L7 | AI settings is a public page in a new subdir, unlike sibling sections (private inline widgets) | `lib/presentation/pages/settings/ai_settings_page.dart:24` | `SettingsSection.ai => const AiSettingsPage()` vs `_AppearanceSection`/`_GeneralSection`/`_SecuritySection`. Defensible given size (well-decomposed into ~13 private widgets). | Optionally make it `_AiSettingsSection`, or extract the other large sections into `settings/` for symmetry. |
| L8 | `removeProvider` leaves the provider's API key in secure storage | `lib/data/repositories/ai_settings_repository_impl.dart:107-123` | Deletes config + routes but never `deleteApiKey`; secret persists and silently resurfaces if a same-id provider is re-added. Retained, not exposed. | In `removeProvider`, also `await _storage.delete(key: _apiKeyKey(providerId))` (best-effort, inside the guard). |
| L9 | Config datasource `_toProvider` mis-tags every row `source=user`, `env=[]`, ignoring the stored `source` column | `lib/data/datasources/ai/ai_config_datasource.dart:162-172` | Diverges from `AiSettingsRepositoryImpl._toProvider` (env `['API_KEY']` for non-local). On cold/offline launch a mis-tagged catalog provider skips the `MissingApiKey` pre-check → wasted 401 round-trip. Narrow edge case. | Derive `source` via `_sourceFrom(e.source)` and reconstruct `env` consistently, or share one mapper between datasource and settings repo. |
| L10 | Anthropic stream emits no terminal `done` chunk if the stream ends without `message_stop` | `lib/data/datasources/ai/inference/anthropic_adapter.dart:179` | On clean close before `message_stop` (proxy/idle), `finishReason`/usage are lost; OpenAI has an `if (!terminated)` fallback, Anthropic doesn't. Cubit `onDone` preserves visible text. | Track a `terminated` flag and emit a synthetic terminal chunk after the loop if `message_stop` was never seen. |
| L11 | OpenAI adapter ignores per-model `provider.shape` (responses vs completions); always POSTs `/chat/completions` | `lib/data/datasources/ai/inference/openai_compatible_adapter.dart:43` | Spec (197-202) says `shape` selects the request variant; `providerOverride` is parsed (`ai_catalog_mapper.dart:110`) but unused. A responses-only model 404s. Deferred-gap. | Branch on `shape`, or filter/disable responses-only models in the picker until implemented. |
| L12 | Raw exception strings interpolated into user-facing `Failure` messages | `lib/data/datasources/ai/inference/openai_compatible_adapter.dart:130,164,239` | `'...: $e'` and verbatim provider 4xx bodies echoed into a SnackBar (`compose_dialog.dart:699`). Dio transport errors use `_mapDioError` (no headers), so the API key isn't exposed; defense-in-depth only. | Map exceptions to fixed user-safe messages; log raw `$e` via a redacting logger; truncate/sanitize provider error bodies. |
| L13 | `refreshCatalog()` can never report a failure — its error handling is dead code | `lib/data/repositories/ai_catalog_repository_impl.dart:125` | `load(forceRefresh:true)` → `_doRefresh()` swallows all exceptions (`catch (e) { debugPrint }`, never rethrows), so the try/catch is unreachable and it always returns `Right(unit)`. Currently unused, so latent. | Have the registry propagate the network error for the explicit `forceRefresh` case, or drop the misleading doc + unreachable try/catch. |
| L14 | Azure inference fallback base URL is a literal placeholder host | `lib/data/repositories/ai_inference_repository_impl.dart:120` | An azure-derived provider with `null api` (`mapper:125`) resolves to `https://YOUR-RESOURCE.openai.azure.com/...` → confusing DNS failure instead of "configure your Azure endpoint." | For azure with null/empty base, return a typed `NoProviderConfigured`-style failure instead of the placeholder. |
| L15 | OpenAI streaming `[DONE]`-less fallback, `ContextTooLong`, and mid-stream error paths untested | `lib/data/datasources/ai/inference/openai_compatible_adapter.dart:244` | Tests always send `data: [DONE]`, so the stream-close fallback (244-255), the 400→`ContextTooLong` heuristic (299), and a mid-stream `DioException` (234) are never exercised. Coverage gap, no proven defect. | Add a no-`[DONE]` stream-close test (exactly one terminal chunk), a 400 context-overflow test, and a mid-stream throw → single `Left` test. |
| L16 | Registry concurrency dedup, warm-path refresh, and conditional/etag handling untested | `lib/data/datasources/ai/ai_provider_registry.dart:149` | `_inFlightRefresh` dedup, the warm `load()` background-refresh branch, and the etag stubs (asserted via `anyNamed`) are uncovered. | Add a two-concurrent-`load()` dedup test, a warm-load test, and either implement+test conditional fetch or trim the doc. |
| L17 | Catalog repo impl, `provider_models` datasource, and schema 7→8 migration untested | `lib/data/repositories/ai_catalog_repository_impl.dart:1`; `app_database.dart` `from < 8` | A broken `onUpgrade` (or un-regenerated `app_database.g.dart`) would only fail at runtime on existing installs. No AI test files were deleted vs main (all new); no-key-gate assertions are justified though redundant. | Add catalog-repo, `provider_models` datasource, and a Drift migration test (v7 DB → migrate → assert the three tables exist). Confirm `build_runner` regenerated `app_database.g.dart`. |
| L18 | Dead datasource methods: `ModelsDevCatalogDatasource.fetchCatalog()` and `AiConfigDatasource.getUserProviders()` | `models_dev_catalog_datasource.dart:22`; `ai_config_datasource.dart:61` | Both declared/implemented but never called in `lib/` (registry uses `fetchRaw()+parse()` and `getConfiguredProviders()`); the stale registry doc still names `getUserProviders()`. | Remove the unused methods (and interface entries) or wire them in; update the registry doc. |
| L19 | google/ollama interim stand-in: the Google default base URL is incompatible with the OpenAI adapter it falls back to | `lib/data/datasources/ai/ai_adapter_factory.dart:37-42` | `_defaultBaseUrl(google)` = `.../v1beta`, but OpenAI adapter POSTs `{base}/chat/completions`; Google's OpenAI-compat surface is `/v1beta/openai/`, so a google route silently 404s. Explicitly deferred/TODO. | Point google's default base at `.../v1beta/openai`, or have the factory throw a clear unsupported failure for google until the real adapter lands. |
| L20 | Stale enum comments omit the added `azure` wire protocol | `lib/data/database/app_database.dart:120`; `ai_config_datasource.dart:26` | Comments still say `openai \| anthropic \| google \| ollama` though `_parseWireProtocol` handles `'azure'`. Doc-only. | Add `\| azure` to both comments. |
| L21 | Registry class-doc contradicts its own field doc/behavior about what gets merged | `lib/data/datasources/ai/ai_provider_registry.dart:20-22` | Class doc says only BYO (`source==user`) providers are merged, but the code merges `getConfiguredProviders()` (BYO **and** catalog picks); field doc (76-79) + `all()` overlay (201-212) say the opposite. | Update the class-level doc to say BYO providers and catalog picks with user endpoints are both merged. |
| L22 | Spec-promised registry API (`forCapability`) and metadata (`installHint`) not implemented or marked deferred | `lib/data/datasources/ai/ai_provider_registry.dart:196-257` | Spec (136-142) lists both; neither exists, with no "deferred" note. Unused convenience helpers; no functional bug. | Add a "deferred per first slice" note in the registry doc, or implement them. |

---

## What's Solid

- **Clean Architecture is respected throughout.** Entities, repository interfaces, usecases, models/datasources/repo-impls, and blocs sit in the right layers; DI is entirely via `get_it` `sl<T>()`. The new code follows the repo's existing conventions faithfully.
- **Failure model mirrors the repo.** New `sealed class AiFailure extends Failure` + six `final class` subtypes match `failures.dart` exactly; datasources (the catalog ones) throw `ServerException`/`NetworkException` and repos convert.
- **Drift migration follows the established pattern.** `schemaVersion` 7→8 with a guarded `if (from < 8)` block creating the three new tables; tables added to `@DriftDatabase`. (Verify `app_database.g.dart` was regenerated and add a migration test — L17.)
- **Cubits match repo conventions.** Named-param constructors, sealed-state switches, `isClosed` emit guards, subscription/timer cancellation in `close()`.
- **Streaming design is well-built.** SSE over dio (`responseType: stream`, `data:` parsing, `[DONE]` terminal, `stream_options.include_usage`), with a graceful stream-close fallback in the OpenAI adapter. The OpenAI UTF-8 path is correct (stateful `utf8.decoder`) — the Anthropic adapter should copy it (M1).
- **Registry is a clean single source of truth** with sensible merge precedence (catalog descriptor + user endpoint overlay), `_inFlightRefresh` dedup, and cold/warm load paths. The catalog/mapper/adapter decomposition is good.
- **Azure support is a reasonable, well-flagged extension** (`api-key` header via `useApiKeyHeader`, deployment listing), and google/ollama stand-ins are explicitly TODO-marked.
- **The 1497-LOC settings page is large but well-decomposed** into ~13 private widgets rather than a god-widget — consistent with how `settings_page.dart` itself is structured.

---

## Privacy "Cloud Bodies" Guard — Status (Read This)

**The single most important issue in this branch.** The spec's conservative default guard ("don't send mail bodies to cloud providers," default safe) exists **only as storage** (`AiSettingsRepositoryImpl.getAllowCloudForBodies`/`setAllowCloudForBodies`, key `ai_allow_cloud_for_bodies`, default `false`). It is:

- **Never read** by `ComposeReply` or the inference repo — the quoted email body is sent to whatever provider is routed, regardless of `AiProviderKind`.
- **Never written** by any UI — the 1497-LOC settings page has no toggle, so a user cannot even enable it.
- **Codified as "correct" by a test** (`compose_reply_test.dart:77-78` asserts the body IS in the prompt), which will block the fix.

Net: at the safe default, a cloud-routed compose silently exfiltrates the user's received email body to a third-party LLM. This must be wired (consumer + UI toggle + corrected test) before merge. Tracked as **H2 (privacy)** and **M5 (test)**.

## Test-Coverage Gaps — Status

Tests present cover registry merge/precedence, adapter factory exhaustiveness, both adapters (incl. SSE fixtures), inference-repo resolution, and `compose_reply`. **Notable gaps:**

- **Untested entirely:** `AiCatalogMapper` derivation (H3 — highest-risk), `AiSettingsRepositoryImpl` incl. the privacy default (M4), both cubits + the compose→editor streaming bridge (M7), `AiCatalogRepositoryImpl`, `ProviderModelsDatasource`, and the Drift 7→8 migration (L17).
- **Partially tested / blind spots:** OpenAI request construction + the Azure `api-key` header (M6), the OpenAI stream-close fallback / `ContextTooLong` / mid-stream error paths (L15), and registry concurrency/warm/conditional behavior (L16).
- **Anti-test:** `compose_reply_test.dart` pins the privacy leak as the contract (M5).

No widget/integration test covers the compose→editor streaming bridge or the settings page, and no migration test exercises the `from < 8` upgrade path.
