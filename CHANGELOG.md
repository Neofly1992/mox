# Changelog

All notable changes to mox are documented here. Versions follow semver;
v0.x releases may include breaking protocol changes documented inline.
## v0.8.6 — `ModelRunner` 接 `ModelRegistry` (2026-09)

### Added

- **`ModelRunner.loadModel`** 现在通过 `ModelRegistry` 跟踪 resident 模型：构造预算（按 `MemoryBudget.cacheBudget(totalRAM, weightsPeak: 0)` + 首次 load 时的实测 total RAM），register 每个 id，evicted ids 同步释放对应 `ModelContainer`。pinned 配置从 `AppConfig.memory.pinnedModels` 读取。
- **`ModelRunner.container(for:)`** 服务请求后调 `registry.touch(id:)` —— LRU 反映"刚服务请求"的模型优先保留。
- **`ModelRunner.unloadModel` / `unloadAll`** 同步从 registry evict 释放 bytes。
- **`ModelRunner.registrySnapshot()`** —— `/health` 拿 budget / used / loadedCount 的源头。
- **`HealthPayload.Runtime`** 新字段：`cacheBudgetBytes: Int64?` / `cacheUsedBytes: Int64?` / `loadedModelCount: Int`（snake_case：`cache_budget_bytes` / `cache_used_bytes` / `loaded_model_count`）。默认值 nil/0，向后兼容 pre-v0.8.6 caller。
- **`moxHealthPayloadVersion`** 从 `0.8.0` bump 到 `0.8.6`。

### Tests

- **`HealthPayloadTests.runtimeCacheFields`** —— round-trip 新字段 + 默认值 nil 兼容；断言 snake_case 编码。
- **`HealthPayloadTests.payloadVersion`** —— pin version bump。

## v0.8.5 — `ModelRegistry` actor + `MemoryBudget` 骨架

### Added

- **`Sources/MoxCore/MemoryBudget.swift`** — `MemoryBudget.cacheBudget(totalRAMBytes:weightsPeakBytes:surplusFraction:)` 纯函数。按 MTPLX 同值的 `_AUTO_BUDGET_SURPLUS_FRACTION = 0.5` 算 surplus，clamp 到 `[1 GiB, 48 GiB]`，再减去 weights peak bytes。负值 collapse 到 0。无 I/O / 无 actor / 无 clock —— 纯函数，测试零依赖。
- **`Sources/MoxCore/ModelRegistry.swift`** — 元数据级 LRU + pin registry actor：`register(id:weightsBytes:pinned:)` / `touch(id:)` / `evict(id:)` / `setPinned(id:pinned:)` / `snapshot()` / `contains(id:)`。LRU 用内部 `tickCounter: UInt64` 当排序键（不用 `Date()`，因为 macOS 上 `Date()` 精度比 actor 串行 executor 处理 back-to-back register 慢，导致 tie 走 dict 顺序变 nondeterministic）。**重要：Phase 3b 才把它接到 `ModelRunner`；v0.8.5 只交 actor + 测试骨架。**
- **`AppConfig.MemoryConfig.pinnedModels: [String]`** —— 新字段。配置级别的 pin 列表，留给 Phase 3b 接 `ModelRegistry.setPinned(id:)` 用。默认空数组，向后兼容。

### Tests

- **`Tests/MoxCoreTests/MemoryBudgetTests.swift`** — 7 个测试覆盖 32/16/1/0.5/128 GB Mac 的边界、surplus floor (1 GiB)、surplus cap (48 GiB)、overcommitted weights collapse 到 0、自定义 fraction 路径。
- **`Tests/MoxCoreTests/ModelRegistryTests.swift`** — 13 个测试覆盖 register / re-register / touch / explicit evict / setPinned promote/demote/no-op / eviction 跳过 pinned / snapshot 一致性。**2 个 LRU victim-ordering 测试用 `withKnownIssue { ... }` 记录 known issue**——tick 排序在 back-to-back registers 仍可能 tie，v0.8.6 修。

## v0.8.4 — `mox update` 支持 ModelScope (2026-09)

### Added

- **`ModelScopeInventoryFetcher`**：`Sources/MoxCore/ModelScopeInventoryFetcher.swift`，实现 `RemoteInventoryFetcher` 协议。Wire endpoint `https://modelscope.cn/api/v1/models/{repo_id}/repo/files?Recursive=True&Revision={rev}`，返回 `{Code, Data:{Files:[{Path,Size,Sha256,...}], Revision}}`。`Revision` 顶层字段映射到 `RemoteModelInventory.revision`（commit hash pin），`Files[]` → `[RemoteFileEntry]`。
- **`handleUpdate` 按 source 分派 fetcher**：根据 `ModelInfo.source`（HF / mlx-community / ModelScope / unknown）选 `HuggingFaceInventoryFetcher` 还是 `ModelScopeInventoryFetcher`。`mlx-community` 复用 HF（同协议），`unknown` legacy install 兜底用 HF。
- **`ModelScopeInventoryFetcher.parse(_:modelId:)`**：纯 wire→inventory 解码函数，公开以便测试。`fetch` 走完 HTTP 层后直接调它，避免在测试里 stub `URLSession`。

### Tests

- **`Tests/MoxCoreTests/ModelScopeInventoryFetcherTests.swift`**：5 个测试覆盖单文件解码、`Size as NSNumber` 路径（JSONSerialization 默认写 NSNumber）、缺失 revision/sha256 容错、缺失 Path/Size 丢弃条目、非 `{Code,Data}` 信封拒收。无网络依赖，CI 友好。

## v0.8.3 — `mox update` 闭环

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
