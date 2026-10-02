# AI Subsystem

Deliberate deviations from the repo's default Clean-Architecture shape for the AI slice (compose reply, provider catalog, inference). See [../../CLAUDE.md](../../CLAUDE.md) for the default shape these deviate from.

## AI Subsystem

The AI slice (compose reply, provider catalog, inference) introduces two
deliberate deviations from the repo's default Clean-Architecture conventions.
They are intentional — do not "fix" them back to the default shape.

### Streaming repositories return `Stream<Either<Failure, AiChunk>>`

`AiInferenceRepository.stream(...)` returns `Stream<Either<Failure, AiChunk>>`
(`lib/domain/repositories/ai_inference_repository.dart`) rather than the usual
`Future<Either<Failure, T>>`. This is a deliberate new repo shape for streaming:
each emitted item is an `Either`, so a mid-stream failure surfaces as a `Left`
on the stream instead of throwing. Single-shot AI repo methods keep the normal
`Future<Either<Failure, T>>` form. Future streaming repos should follow this
same `Stream<Either<Failure, T>>` shape.

### AI wire adapters return `Either<Failure, T>` directly

Unlike the catalog datasources (which throw `ServerException`/`NetworkException`
for the repository to convert), the inference wire adapters
(`lib/data/datasources/ai/inference/ai_adapter.dart` and impls) return
`Either<Failure, T>` directly rather than throwing. This is intentional:
streaming forces it — you cannot "throw then convert in the repo" across an
async stream, so the adapter must emit `Left(failure)` inline. For consistency
the single-shot adapter path returns `Either` the same way rather than mixing
throw-and-convert with emit-`Left` in one class.


### One tool-calling loop, two agents

`AgentLoop` (`lib/domain/usecases/ai/agent/agent_loop.dart`) is the
stream-a-round / run-the-tools / feed-back-results loop. `RunFolderAgent`
(mail tools, Compose route, no-tools fallback) and `RunCommitmentsAgent`
(ledger tools, Compose route, no fallback — see
[commitments.md](commitments.md)) both delegate to it; the two sentinel
finish reasons the UI renders as tool cards live there, with
`RunFolderAgent` keeping aliases so nothing that imported them moved. On
the presentation side `AgentChatCubit` owns the transcript (text bubbles
interleaved with tool cards, turn-tagged history trimming) and
`AiFolderCubit` / `CommitmentsAgentCubit` only supply the turn.

### System One (typed decision) providers speak a non-chat wire

`AiWireProtocol.systemOne` is TypeSafe's Jev API: `POST {base}/v1/systemone`
with `{model, state, questions}` → `{model, answers, usage}`. Each question is
`noul` (yes/no → P(true)), `choice` (named options → pick + probabilities) or
`score` (ordered rubric → expected level). These models generate **no text**,
so the slice splits the adapter boundary in two:

* `AiAdapter.run`/`stream` — chat. The System One adapter refuses them with
  `UnsupportedFailure`.
* `AiAdapter.decide` (and `AiInferenceRepository.decide`) — typed decisions.
  The base class carries a default `decide` that refuses with
  `UnsupportedFailure`, which is why the chat adapters **extend** `AiAdapter`
  rather than implement it; only `SystemOneAdapter` overrides it.

`AiProvider.supportsChat` / `supportsDecisions` are the single switch the UI
and the repository use: the inference repository fails closed *before* the
factory for a mismatched request, and the settings page's Features table only
offers each provider to the rows it can serve — Compose (and the folder agent,
which reuses Compose's route) lists chat providers; Triage lists decision
providers. Triage has no consumer yet: its route is persisted under
`capability_routing.triage` for the upcoming triage use case, and the only
caller of `decide` today is the "Test decision" probe in a System One
provider's tile.

models.dev catalogs text APIs only, so `AiCatalogMapper` synthesizes two
entries the way it does the local `ollama` one:

| id | kind | key | default endpoint | models |
|---|---|---|---|---|
| `jev` | cloud | yes (`jv_live_…`) | `https://api.typesafe.ai/v1` | static `jev-latest`, `jev-preview` — the API has no models route |
| `laya-mlx` | local | none | `http://127.0.0.1:8766/v1` | listed live from the bridge's `/v1/models` |

**laya-mlx has no HTTP server.** It is a Python library (`agent.predict(state,
questions)`), but its result dict is already byte-for-byte Jev's response
shape, so a bridge only has to put the Jev routes (`POST /v1/systemone`,
`GET /v1/models`, `GET /healthz`) in front of one loaded checkpoint. **That
bridge is provisioned outside this repo** (David's ansible project), and
NightMail must never install, start or manage it — it only dials
`http://127.0.0.1:8766/v1`; a refused connection there is reported as "the
bridge is not running". Port 8766 was chosen because the other Jev-compatible
local servers already took theirs (local-jev 8765, jevlocal 9011, OpenJev
8080); any of those can be added as a *Custom endpoint* with the System One
protocol — a loopback URL is classified `local`, anything else `selfHosted`.
Like Ollama, a System One base URL is normalized to end in `/v1`
(`AiProvider.defaultBaseUrl`), because every server documents a bare host
while the route lives under `/v1`.
