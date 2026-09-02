# Changelog

All notable changes to mox are documented here. Versions follow semver;
v0.x releases may include breaking protocol changes documented inline.
## v0.8.3 — `mox update` 闭环（2026-09）

### Fixed

- **`mox update` 改 sha256.txt**：之前 update 后 `sha256.txt` 不重算，下次 `mox list --check` / 再 diff 会把刚下载的文件当 unchanged 直接跳过。v0.8.3 每次 download 完都重新 hash 全目录的权重文件并写回 `sha256.txt`（`mox.json` / `sha256.txt` 自身跳过，避免鸡生蛋）。
- **`mox update` pin revision**：`ModelManifest.revision: String?` 新字段；`ModelUpdater.update` 把远端 inventory 报的 revision pin 写回 `mox.json`。远端 `nil` 时保留已有 pin（避免把历史 pin 抹掉）。legacy install `revision` 默认 `nil`，向后兼容。

### Improved

- **`mox update` 多文件进度聚合**：之前每个文件进度独立 0..100%，多文件时看起来永远卡在第一个文件。`UpdateProgressTracker`（NSLock-protected）累计字节到 `plan.totalBytesToFetch`；CLI 端不再需要改 — `DownloadProgress.bytesDownloaded` 已经是累计值。

### Tests

- **`Tests/MoxCoreTests/ModelUpdaterTests.swift`**：4 个测试用 in-memory `StubFetcher` / `StubDownloader` 覆盖 sha256 重算、revision pin、nil-revision 保留、多文件进度聚合。无网络依赖，CI 友好。

## v0.9.0 — `mox convert` + `mox re-quantize` + pull auto-quantize (2026-09)

### Added (shipped)

- **`MoxConvertCore.MoxQuant.quantize(sourceDirectory:options:)`** —
  pure-Swift pipeline that takes a HF bf16 / fp16 / fp32 model
  directory and writes a quantised MLX safetensors sibling. Wires
  the three upstream primitives — `MLXNN.quantize`,
  `Module.parameters().flattened`, `MLX.save(arrays:url:stream:)` —
  through `MLXLMCommon.loadModelContainer`. No Python, no subprocess.
- **`mox convert <dir> [--q-bits N] [--q-group-size N] [--mode M] [--output DIR]`** —
  CLI wrapper around `MoxQuant.quantize`. Flags default to the MLX
  defaults (4-bit, group 64, affine). Output defaults to a sibling
  `<dir>-<bits>bit/` so the source is preserved. Prints a
  before/after byte delta on success.
- **`mox re-quantize <dir> [--q-bits N] [--q-group-size N]`** —
  CLI wrapper that re-runs the same pipeline on an already-installed
  MLX model directory to flip 4-bit ↔ 8-bit. Aliases: `requantize`.
- **`mox pull` auto-quantizes bf16 / fp16 / fp32 to 4-bit MLX** —
  after a successful pull, `handlePull` inspects the destination
  directory and, if `MoxConverter` classifies it as HF precision,
  kicks off `MoxQuant.quantize` against a `<dir>-4bit/` sibling.
  The new sibling gets a rewritten `mox.json` with
  `sourceFormat = "mlx-4bit-affine"` and a populated
  `quantization = MoxQuantizationInfo(bits:4, groupSize:64, mode:"affine")`
  so subsequent `mox run` lands on the quantized weights. The raw
  HF directory is left untouched. Opt out with `--no-auto-quantize`
  for users who want full precision or whose machines can't afford
  the extra peak memory.
- **`Tests/MoxCoreTests/MoxQuantIntegrationTests.swift`** — 4 tests
  pin the contract around `MoxQuant.quantize`: output directory is
  created, the loader's failure on an invalid model is surfaced as a
  typed error rather than a trap, and missing-source paths are
  rejected cleanly. No real weights needed in CI.

### Background (the design rationale)

`mox convert` ships in v0.9. The backend is already in the dependency
graph (mlx-swift 0.31.6, the version mox pins today):
- `MLXNN.quantize(model:groupSize:bits:mode:filter:apply:)` quantizes
  a Module to 4-bit / 8-bit / mxfp4 / mxfp8.
- `Module.parameters().flattened(prefix:)` flattens the nested
  parameter dict to `[String: MLXArray]`.
- `MLX.save(arrays:metadata:url:stream:)` writes `.safetensors` on disk.

Until v0.9, `mox pull Qwen/Qwen2.5-7B-Instruct` downloads 14 GB bf16
weights and either forces the user to convert via Python tools or
runs the model at full bf16 footprint. Both fail DESIGN §0 ("Mox
does not introduce a Python dependency"). v0.9 fixes this by
wiring the three calls above into a single CLI command, plus the
`mox pull` auto-quantize hook so the user never has to run a second
command manually.

---

## v0.9.0 onwards — next

The next three big lifts land in **v1.0.0**; see ROADMAP for details:
- Continuous batching (§9.2)
- Reasoning / thinking budget (§9.3)
- Paged SSD cold tier (§10.1)



## v0.8.1 — Code-quality audit fixes

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

### Notes

- v0.8.0's `Server.swift` shipped with a partial refactor that left
  `MoxHTTPHandler.channelInactive` and `finishPending` declarations
  missing; tests passed because the test target didn't compile
  `Server.swift`. v0.8.1 restores both declarations and confirms the
  four endpoints (`/health`, `/v1/chat/completions`,
  `/v1/embeddings`, `/v1/messages`) plus 404 routing work
  end-to-end via real-machine smoke.

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
