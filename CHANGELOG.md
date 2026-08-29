# Changelog

All notable changes to mox are documented here. Versions follow semver;
v0.x releases may include breaking protocol changes documented inline.

## v0.8.1 — Code-quality audit fixes

### Changed

- **Server.swift dispatch is now table-driven** (`HTTPRouter.routes`):
  new endpoints add one line, no edits to the dispatcher.
- **Single JSON response writer** (`JSONResponse.write` /
  `JSONResponse.writeError`): replaces the previous 90%-duplicated
  `respond` + `respondAnthropicJSON` + `respondError` +
  `respondAnthropicError` quartet. OpenAI / Anthropic envelope differences
  are now a `kind:` enum parameter; the legacy methods stay as thin
  shims to minimise call-site churn.
- **`OpenAIErrorBody` / `OpenAIErrorPayload` moved to MoxShared** so
  the dispatcher and the channel-read early-exit paths share the same
  wire types.

### Fixed

- The build now compiles. A previous partial refactor had left
  `MoxHTTPHandler.channelInactive` and `finishPending` in a broken
  state; the file now has both declarations back and the class closes
  properly. Smoke tests confirm the four endpoints (`/health`,
  `/v1/chat/completions`, `/v1/embeddings`, `/v1/messages`) plus
  404 routing all work end-to-end.

## v0.8.0 — 工具调用 + 兼容性分级 + 增量下载

### Added

- **`ToolCallParser` registry** (`MoxShared.ToolCallParser`): single XML
  parser + `LlamaJsonToolCallParser` covering Qwen2/3, Llama, Mistral,
  Mixtral, DeepSeek families. OpenAI `/v1/chat/completions` accepts
  `tools` and parses model output for `<tool_call>...</tool_call>` /
  JSON forms; results emit as `OpenAIToolCall` on the assistant message
  with `finish_reason: "tool_calls"`. Tool entries with empty `name` are
  rejected at the resolver with a structured 400 (`tools[i] missing
  required string field 'name'`).
- **`CompatibilityTier` enum** + `CompatibilityProbe`
  (`MoxConvertCore`): five-tier classification —
  `mlxBuiltin` / `communityUnverified` / `arOnly` / `incompatible` /
  `unknown`. Persisted in `ModelManifest.compatibility` and surfaced via
  `/health.models[].compatibility`. Re-probed at load time; mismatch
  reports the diff rather than overwriting.
- **`ModelManager.readManifest(at:)`**: typed manifest accessor for the
  load path; `LoadedModel` now carries `compatibility` + `compatibilityReason`
  for `/health`.
- **Delta download scaffolding** (`MoxShared.ModelInventory`,
  `ModelDiffEngine`, `LocalInventoryBuilder`): pure-function diff between
  a remote manifest and the local cache; `mox list --check` walks each
  installed model and prints `cached files + bytes`; v0.9 ships the
  remote probe that closes the loop with `mox update <id>`. `Downloader.probe`
  now exposes `etag` and `lastModified` from the response headers.
- **`/v1/embeddings` endpoint scaffold**: full OpenAI wire contract
  (`EmbeddingRequest` / `EmbeddingResponse` / `EmbeddingUsage`) returns
  a structured **501 Not Implemented** with `code: "embeddings_not_implemented"`.
  v0.9 adds the actual inference actor.
- **`ModelCompatibility` round-trip**: new field on `ModelManifest`,
  serialized via Codable. Existing manifests without the field decode
  cleanly (default nil).
- **`/health` v0.8 flags**: `capabilities.tool_calls: true`,
  `openai_completions: true`; `embeddings: false`. `models[].compatibility`
  string + `compatibility_reason`.

### Changed

- **`RequestPolicy.tools`**: v0.7 hard-rejected `tools` with 400; v0.8
  validates each entry has a non-empty `name` and threads them through
  to the parser layer.
- **`ResolvedRequest`**: gains `tools: [AnyCodable]` and
  `modelFamilyHint: String?` for downstream parser dispatch.

### Test coverage

- `ModelDiffEngineTests`: 7 cases (empty cache / size match / size
  mismatch / partial fetch / revision propagation / subdirectory paths /
  hash mismatch cheap path).
- `LocalInventoryBuilderTests`: 2 cases (empty dir / recursive walk +
  manifest skip).
- `CompatibilityProbeTests`: 9 cases (missing config / mlxBuiltin +
  quant / mlxBuiltin bare / arOnly / unknown family / missing model_type /
  manifest round-trip + 2 mismatch/match cases).
- `ToolCallParserTests`: 9 cases (plain text pass-through / XML form /
  JSON form / multiple calls / registry routing / unique IDs / empty
  args / malformed / fallback).
- `EmbeddingTests`: 5 cases (single + batch decode / round-trip /
  response shape / 501 envelope).
- `HealthPayloadTests` updated for v0.8 capability flags.

Total: 109 tests, up from 76 in v0.7.

### Source layout

- New: `Sources/MoxShared/RequestPolicy.swift` (touched in v0.7),
  `Sources/MoxShared/ModelInventory.swift`,
  `Sources/MoxShared/Embedding.swift`,
  `Sources/MoxShared/ToolCallParser.swift`.
- New: `Sources/MoxConvertCore/CompatibilityProbe.swift`,
  `Sources/MoxCore/LocalInventoryBuilder.swift`.
- New: `Tests/MoxCoreTests/ModelDiffEngineTests.swift`,
  `Tests/MoxCoreTests/LocalInventoryBuilderTests.swift`,
  `Tests/MoxCoreTests/CompatibilityProbeTests.swift`,
  `Tests/MoxCoreTests/ToolCallParserTests.swift`,
  `Tests/MoxCoreTests/EmbeddingTests.swift`.

### Known gaps (deferred to v0.9)

- `mox update <id>` actual download path — engine and inventory are in
  place; needs the remote probe / source-specific fetcher.
- Family-specific tool-call parsers beyond XML — omlx ships 8+; we
  cover the most common shapes via XML and have the protocol surface
  ready for per-family extensions.
- Anthropic `tool_use` translation — the OpenAI side is wired; the
  Anthropic-side `tool_use` ↔ `tool_calls` conversion is v0.8.x.
- Embedding inference — wire contract + 501 are in v0.8; the MLX
  embedder actor lands in v0.9.

### See also

- `ROADMAP.md` — full v0.7 → v1.0 plan; v0.8 items above are checked off,
  v0.9 onwards is next.
