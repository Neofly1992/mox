# 路线图（见贤思齐）

**基线版本**：v0.6（2026-08）
**审视对象**：`/Users/neo/Code/libre/omlx`、`/Users/neo/Code/libre/MTPLX`
**方针**：竞品的产品面（多模型、tool call、admin UI）分批补齐；架构和工程实践挑**契约性、可证伪、低工程量**的点；保留 Swift 栈已有的优势（actor 隔离、Sendable、单一二进制、错误显式化），不为对齐竞品而丢。

每个条目格式：**动机** → **做法** → **验证** → **不做什么**。

---

## v0.7 — 协议补齐 + 契约外露 ✅ v0.7.0 已交付 (2026-08)

### 7.1 OpenAI `/v1/chat/completions` SSE 流 + `stream_options.include_usage` ✅

**动机**：Claude Code、Codex、Open WebUI 等主流客户端默认走 OpenAI 协议；mox v0.6 仍是非流式 JSON，长输出场景体验断崖。omlx/MTPLX 都把 SSE 当默认。

**做法**：在 `MoxServer.Server.swift` 已有 Anthropic SSE handler 上加 OpenAI 路径。复用 `AsyncStream<String>`，把现有 Anthropic 的 `event:`/`data:` 协议换成形如 `data: {"id":"...","object":"chat.completion.chunk","choices":[{"delta":{"content":"tok"}}]}\n\n`，末尾 `data: [DONE]\n\n`。`finish_reason` 只在最后一条发；usage 按 `stream_options.include_usage` 决定是否发 usage chunk。

**验证**：
- `curl -N http://127.0.0.1:11555/v1/chat/completions -d '{...,"stream":true}'` 收到连续 chunk。
- Anthropic SDK 路径不回归（`/v1/messages` 流式字节不变）。
- `stream_options: {"include_usage": true}` 时收到 `choices: []` + `usage` 的最终 chunk。

**不做**：SSE keep-alive 心跳（等真有 read timeout 案例再加）；tool call 的流式分片（v0.8 一起做）。

### 7.2 `/v1/completions`（legacy）✅

**动机**：aider、tabby、若干老 client 只认 legacy prompt endpoint。omlx/MTPLX 都暴露。

**做法**：复用 OpenAI chat handler 的 prompt 构造部分，把 `{role, content}[]` 拍平成单字符串，按模型家族选择 chat template 的"裸 prompt"路径。SSE 同 7.1。

**验证**：`curl -d '{"model":"...","prompt":"hi","stream":true}'` 返回 chunk 流，stop 后 `[DONE]`。

**不做**：echo、logprobs、best_of（无用户需求时不分摊复杂度）。

### 7.3 `/health` 暴露能力面 ✅


**做法**：把 `MoxCore` 现有 `ModelRunner` actor 暴露的能力字段（`isReady` / `loadedModelId` / `loadedModelFamily` / `supportsToolCalls` / `maxContextTokens` / `samplerDefaults` / `streamChunkIntervalMs`）序列化进 `/health` JSON body。设计为可前向兼容：未知字段客户端忽略；新增字段加 `since` 标签便于客户端判版本。

**验证**：
- 客户端 SDK（自家 `MoxGUIClient`）启动时读 `/health`，GUI 显示模型家族和上下文上限。
- 写一个 MoxCoreTests：cold start / model loading / model loaded / model unload 四种状态下 `/health` 字节级断言。

**不做**：`/metrics` Prometheus 格式（v0.9+ 再评估）。

### 7.4 启动 warmup + `/health` 联动 ✅
**动机**：omlx/MTPLX 都在 model 加载后跑小段生成做端到端验证。**weights 加载完 ≠ server 可用**——首次 prefill / kv cache / chat template / sampler 链路任何一环出问题，客户端才会发现，体验是"server 看着健康但请求全挂"。MTPLX `--strict-warmup` 让 warmup 失败 fatal。

**做法**：model 加载完成后，`ModelRunner` actor 在自己线程跑 8-16 token 的 `Hello` 生成；成功才把 `/health.isReady` 翻 true。失败时 daemon 进程退出非 0，launchd 不重启（`KeepAlive: false` 在 install 时设置），`mox-server status` 返回明确错误码。

**验证**：
- 故意传错模型 id（sibling 损坏），`mox-server status` 应报 warmup failed + exit code ≠ 0。
- 正常模型 warmup 后 `isReady` 在 1-3 秒内变 true，CLI 端到端延迟可接受。

**不做**：动态 `/health` status 变 false 时让客户端重试（客户端策略问题，不在 server 责任）。

### 7.5 RequestPolicy 共享解析路径 ✅

**做法**：在 `MoxShared` 新建 `RequestPolicy.swift`，定义：
- `enum SamplerSource { case client, server, default }`
- `enum ClientControlField { case temperature, topP, topK, maxTokens, stop, stream, tools, responseFormat, ... }`
- `ResolvedRequest` 值类型：所有字段都 server-resolved 后冻结。
- `RequestPolicy.resolve(_ raw: RawRequest, serverConfig: ServerDefaults) throws -> ResolvedRequest`

OpenAI handler、Anthropic handler 都先调 `RequestPolicy.resolve`，得到 `ResolvedRequest` 后再路由到 generation。错误优先级明确：空 prompt → 不支持模型 → tool call 暂未实现 → sampler 非有限数 → 其余约束。

**验证**：
- MoxCoreTests：同一 raw 请求，分别走 OpenAI / Anthropic / Completions handler，resolution 字节相同。
- `tools` 字段当前不支持时，三个 endpoint 都返回同一 400 错误体。
- 字段缺省值（如 OpenAI 不带 temperature）三个 endpoint 都解析成 server default（不是 `nil`）。

**不做**：把 `RequestPolicy` 抽象成 protocol / 反射注册。Swift enum + 函数足够。

## v0.8 — 工具调用 + 模型路由 ✅ v0.8.0 已交付 (2026-08)

### 8.1 Tool calling parser registry ✅ (基础版 — 单 XML parser 覆盖 Qwen/Llama/Mistral/DeepSeek) — 见 §11 上游 6 个 parser 评估 v0.11 P2


**动机**：omlx 暴露 8+ 个 family parser（Llama/Qwen/DeepSeek/Qwen3.5 XML/Gemma/GLM/MiniMax/Mistral/Kimi K2/Longcat）。Claude Code 走 Anthropic tool_use 协议，**不支持 tool call 等于失去 agent 用户群**。当前 mox 走 400 拒，是 v0.6 文档里最大的"未交付"项。

**做法**：在 `MoxCore` 新建 `ToolCallParser`：
- `protocol ToolCallParser { func parse(text: String, tokenizer: Tokenizer) -> [ToolCall] }`
- `enum ModelFamily { case llama, qwen, qwen35, deepseek, gemma, ... }`，每家一份实现。
- 模型加载时根据 tokenizer 的 `tool_call_start` / `tool_call_end` special tokens 选 parser（mlx-swift-lm tokenizer 已有这些字段）；fallback 到 chat template 字符串扫描 `<tool_call>` 字面量（omlx `_chat_template_supports_tool_role` 的思路）。
- OpenAI handler 在请求有 `tools` 时启用 parser，streaming 时边产 token 边增量解析；助手文本和 tool_call 分开发 delta。
- Anthropic handler 把 OpenAI-style 的 `tool_calls` 翻译成 `content_block` of type `tool_use`，tool result 反向翻译成 `role: "tool"` + `tool_call_id`。

**验证**：
- 现有 MoxCoreTests 加 tool call 测试夹具（每 family 一个 .json）。
- Qwen2.5-7B-Instruct 跑 `tools` 请求，能拿到结构化 tool_call。
- streaming 时 `delta.tool_calls` 增量拼接出完整 arguments JSON。
- malformed tool call 不挂请求，按 OpenAI 规范降级成 assistant content。

**不做**：MCP server 桥接（omlx 那个 `[mcp]` extras 的事）—— 等用户真要再说。

### 8.2 模型兼容性分级 ✅

**动机**：MTPLX 把模型分级 verified / architecture-compatible unverified / AR-only / incompatible architecture / no MTP，加载前 probe，加载后立刻 label。**用户看不到的 silent fallback 是最大的反模式**。

**做法**：在 `MoxConvertCore.ManifestInspector`（已存在）基础上加 `ModelCompatibilityProbe`：
- 读 tokenizer.special_tokens + chat template + config.json 的 `architectures` / `model_type`。
- 五档 enum：`verified / mlxBuiltin / communityUnverified / incompatible / noMlxBackend`。
- `mox pull` 时探测写进 `mox.json` 的 `compatibility` 字段。
- 加载时读字段 + 运行时再 probe 一次确认（防止 manifest 被改过），不兼容直接拒绝启动并打印 roadmap pointer（指向 mlx-swift-lm 支持的 model_type 列表）。
- `unverified` 档允许运行但 `/health` 和 CLI 显式 label。

**验证**：
- 拉一个 mlx-swift-lm 不支持的 model_type（如旧 OPT），`mox run` 直接 400 + 清晰错误。
- 拉一个 mlx-community 的转换版本（mlxBuiltin），无 label 干净跑。
- 手工改坏 mox.json 字段，启动时探测不匹配就报错而不是静默跑。

**不做**：构建一份"内部 verified model 列表"——那是 MTPLX 闭源商业化前提下的产物，mox 是 MIT 工具，不替用户验证。

### 8.3 多 model 实例 + 内存预算 ✅ v0.8.5 + v0.8.6

**动机**：用户真实场景 = 聊天 + RAG embedding 并发；agent 同时调两个不同家族的模型做 ensemble。当前 mox 一个进程只能 hold 一个 model，重启即切换。

**做法**：
- 新建 `MoxCore.ModelRegistry` actor：模型路径 → actor 引用，LRU eviction，pin 防 evict，TTL idle unload。
- `MemoryBudget.hardwareAware(totalRAMBytes:, weightsPeakBytes:)`：按 `_AUTO_BUDGET_SURPLUS_FRACTION = 0.5`（MTPLX 同值）算 cache 预算，floor 1 GB、cap 48 GB。
- `mox run --model <id>` 注册进 registry；`/v1/chat/completions` 请求按 `model` 字段路由。
- 内存超预算时 LRU evict 最久未用模型；`/health` 报告当前加载集合 + 预算使用率。
- pin 模型：配置文件 `pinned: ["Qwen/Qwen2.5-7B-Instruct"]` 跳过 LRU。

**验证**：
- MoxCoreTests：内存 mock 下，连续注册 3 个 7B 模型，registry 在第三个加载时 evict 最久未用的。
- 真机：连续切 3 个模型，前两个再访问时 cold reload 时间一致（pin 行为正确）。
- 内存预算边界：满 RAM Mac（96GB+）能 hold 3 个 27B；32GB Mac 不会爆。

**不做**：模型预热优先级 / 排队策略（v0.9+ 再说）；SSD spillover（v0.9）。

### 8.4 增量下载 ✅ ✅ v0.8.3 全闭环

**动机**：MTPLX 2.9.0 的核心卖点之一——`mtplx models --check` + `--update`：重新下载 240-450 MB 而不是 15-21 GB。`mox.json` manifest 已经写了 SHA-256 + revision pin，**只差一步：HTTP HEAD + diff**。

**做法**：在 `MoxCore.Downloader`（已有）加：
- 拉模型前先 HEAD 每个文件拿 ETag / Content-Length / Last-Modified，跟本地对比。
- 只下 hash 不匹配或本地缺的文件。
- `mox list --check`：对比本地 + 远端 revision，输出 update 可用列表 + 预估下载量。
- `mox update <id>`：实际执行增量下载，保留 mox.json 和用户自定义文件。

**验证**：
- 改一个 safetensors 文件，重新 `mox update` 只重下这一个文件。
- `mox list --check` 输出 byte 大小跟实际下载量一致（±5%）。
- 网络中断恢复：resume 用现有 HTTP Range 逻辑（已在 Downloader 里）。

**不做**：跨 source 切换（huggingface ↔ modelscope 互转）；那是 source registry 层面的事。

### 8.5 `/v1/embeddings` 框架 ✅ (wire 完整 + 501 Not Implemented) — 实装推到 v0.11 P0（接 MLXEmbedders 上游 4 模型）

**动机**：MTPLX 把 embedding/rerank 同 daemon 跑，agent memory 不用起第二个 server。**注意：mlx-swift 生态 embedding 支持还在演进，框架先做、模型后接。**

**做法**：
- `/v1/embeddings` + `/v1/rerank` endpoint 框架，按 OpenAI 规范定义 Request/Response 类型（在 `MoxShared`）。
- `MoxCore.Embedder` actor 协议接口；v0.8 默认返回 `501 Not Implemented` + 清晰 roadmap 提示。
- 文档说清楚 v0.9+ 接 mlx-swift embedding 时只需要换实现。

**验证**：endpoint 形态正确（Pydantic 客户端能 introspect Request schema），返回 501 时 body 是结构化错误。

**不做**：v0.8 内任何实际 embedding 计算。

---

## v0.9 — 格式转换 + KV 缓存 + 性能

### 9.0 `mox convert` + `mox re-quantize` CLI ✅ v0.9.0 已交付 (2026-09)

**动机**：现在 `mox pull Qwen/Qwen2.5-7B-Instruct` 只能拿到 14 GB bf16 原始权重，要么强迫用户自己用 Python 工具转 MLX 4-bit，要么就硬吃 14 GB 跑（慢、内存高）。这两条都违背 DESIGN §0 "Mox 不引入 Python 依赖"——前者把用户赶到 Python，后者逼 mox 启动吃 14 GB。`mox convert` 一行命令搞定。

**做法**（DESIGN §15.2.1 的目标，v0.9 落地）：
- `MLXNN.quantize(model:groupSize:bits:mode:)` 把已加载的 MLX Module 量化成 4-bit / 8-bit / mxfp4 / mxfp8。
- `Module.parameters().flattened(prefix:)` 把 nested dict 拍平成 `[String: MLXArray]`。
- `MLX.save(arrays:metadata:url:stream:)` 写 `.safetensors` 到本地 `~/.mox/models/<id>/`。
- `mox convert <hf-id> --q-bits 4 --q-group-size 64 --mode affine` 串起 load → quantize → save。
- `mox re-quantize <local-model> --bits 8` 复用同一 pipeline 改 bit width。
- `mox pull` 检测 config.json 无 `quantization_config` 字段时自动触发 `mox convert`（DESIGN §15.3 路径 B）。

**验证**：
- 拉 `Qwen/Qwen2.5-0.5B-Instruct`（bf16 ~1 GB）→ `mox convert --q-bits 4` → 本地应有 ~500 MB safetensors 文件。再次加载时**直接走 MLX 量化路径**，无 1 GB 内存占用。
- `mox re-quantize mlx-community/X-4bit --bits 8` → 8-bit 权重 → 重新加载 OK。
- 端到端 chat completion smoke：bf16 原始模型 → convert → 加载 → token 输出非空、stop_reason="stop"。

**不做**：custom apply 函数（DESIGN §15.2.1 的 `quantize` 第三个重载，留给需要 per-layer 自定义配置的极小众场景）；MLX-Python 的 AWQ / GPTQ 算法（mlx-swift 没暴露）；跨量化格式互转（`mlx-community` 转 `MLX` 已有 `--quant-palette` 之类工具，不是 mox 的责任）。

### 9.1 Prefix hash + block sharing in RAM ⏳ 写了未做 — 推到 v0.12+ (等上游 KVCache API)

**动机**：长 agent session 里 system prompt + 工具描述 + 前几轮对话几乎不变，prefix cache 命中省一次完整 prefill。omlx block hash + CoW 设计的核心动机；MTPLX SessionBank warm prefix 是同思路。

**做法**：
- 新建 `MoxCore.PrefixCache` actor：`(prefixTokenHash → KVCacheHandle)` 表。
- hash 算法：rolling hash over token id 序列，每 256 token 算一个 block hash（omlx block size）。
- 请求进入时 tokenize → 算前缀 hash → 命中块数 → 只对未命中部分 prefill。
- mlx-swift-lm 的 KVCache 如果不暴露底层引用，**就在 MoxCore 层维护一个 `Token[] → Array` 的引用映射**，命中时把已有 arrays `mx.array` 引用塞回去（mx 是 reference-counted，可行）。**截至 mlx-swift-lm 3.31.3 KVCache 仍为 opaque，引用级 CoW 无法在 mox 层实现**；v0.12+ 需先看上游 API 进展。

**验证**：
- Benchmark：同一 system prompt + 工具描述（~500 tokens），第二次发起同 prompt 请求，prefill 时间降到 < 20%。
- 不同前缀（不同 system prompt）不会误命中。

**不做**：SSD tier（v1.0+）；CoW 的 CoW（mlx-swift KV 已是 immutable array，无需 CoW）。

### 9.2 Continuous batching 接入准备 ⏳ 部分做了 / 关键 API 未到位

**动机**：omlx 抄 vLLM scheduler 跑 mlx-lm `BatchGenerator`，多请求并发时吞吐翻倍。当前 mox 一次一个请求独占 GPU。

**做法**：
- 短期：MoxServer 加进程级 FIFO 队列，`/v1/chat/completions` 多请求按到达顺序串行处理（single runner + queue），单进程多 client 不再直接 reject。
- 中期：等 mlx-swift-lm 出 BatchGenerator 绑定（跟踪上游 issue），抄 omlx scheduler 的 request lifecycle（`waiting → running → finished`）做成 Swift actor。**截至 mlx-swift-lm 3.31.3 上游无 binding**；v0.11 仅做短期 FIFO 队列（如 §P0.x 或独立 PR），中期推迟到 v0.13+。
**不做**：scheduler 调度策略（FCFS / SJF / priority）—— 等 batch 真接入了再说。

### 9.3 Reasoning / thinking budget ⏳ 写了未做 — v0.11 P1

**动机**：Qwen3、DeepSeek-R1、GLM5、Claude 都出 thinking。GUI 默认折叠 thinking 只显示最终回答，开关可切。omlx/MTPLX 都做了。

**做法**：
- parser 检测 chat template 是否有 `<think>...</think>` 段或 `reasoning_content` 字段。
- `MoxShared.ChatCompletionChoice` 加 `reasoning_content: String?`（OpenAI 兼容扩展）。
- Anthropic 侧按 MTPLX 做法映射到 `content_block type: "thinking"` + `thinking_delta`。
- GUI 端对话 tab 加折叠 toggle（mox DESIGN v0.3 已经规划）。

**验证**：
- Qwen3-8B 跑请求，`reasoning_content` 字段填充、最终 message 只显示 answer。
- Anthropic 流式 `thinking_delta` 事件正常推送。

**不做**：thinking token 预算截断（max_thinking_tokens）—— 用户没要。

### 9.4 硬件感知 default model ✅ v0.10.0 已交付 (2026-09)
**动机**：MTPLX 按 M1/M2/M3/M4/M5 + 内存选推荐模型，32 GB 以下推荐 9B、64 GB+ 推荐 27B。

**做法**：
- `MoxShared.HardwareClassifier`：`uname -m` + `sysctl hw.memsize` + `sysctl machdep.cpu.brand_string`，解析 `m1/m3/m4/m5/unknown`。零 actor / 零 I/O / 纯值类型。v0.10.1 起从 `MoxCore` 迁到 `MoxShared` —— `MoxGUIClient` 依赖 `MoxShared` 而不依赖 `MoxCore`，迁过去之后 GUI 可以直接用，无需 RPC 代理。
- `MoxShared.DefaultModelSuggester`：按 `totalRAMGB` → `Tier { toy / small / medium / large }`，输出有序 `recommendedIDs: [String]` + `notes`。Intel 走 Rosetta 兜底。同步迁到 `MoxShared`。
- `mox suggest` 子命令：打印 `Detected: <brand>, <N> GB RAM (<tier> tier)` + 有序推荐，第一项已装时标记 `(already installed)`，否则给 `mox pull <id>  then  mox run <id>` 提示。
- `mox chat`（含 `mox -m`）无 model id 时改为 fallback 到 `handleSuggest` —— 用户第一次敲 `mox chat` 不再撞 "Model ID required" 错误，而是先看到硬件感知推荐，再显式 `mox chat <id>` 进 REPL。

**验证**：
- 真机（Apple M4 16 GB）跑 `mox suggest` → 输出 `(small tier)` + Qwen2.5-7B / Llama-3.1-8B / Qwen2.5-3B 三项。
- `HardwareClassifierTests` 9 例覆盖每代 chip + Intel 翻转 + 零字节兜底；`DefaultModelSuggesterTests` 11 例覆盖四档 + 三个 tier 边界 + Intel + 唯一性。
- Intel 路径输出 "Intel Mac detected — MLX won't run" 而非 MLX 推荐（避免引导用户去 pull mlx-community）。

**不做**：自己维护一份"verified model catalog"——MTPLX 闭源前提的产物，mox 不做商业 curated list。`HardwareClassifier` 不做总速率 / memory pressure 探测（System 框架级别的内存压力对 MLX 模型预热时机有用，但 ROADMAP 没要求，留在 v1.0+）。

**已知边界**：`HardwareClassifier` 只解析到 m5；m6 / 未来世代走 `.unknown` —— 不会 crash，但 RAM tier 仍按实测字节判断，所以推荐逻辑不会失真。

---
## v0.11 — 客户端可用 + 协议补齐 + mlx-swift-lm 上游能力消费 (2026-09 候选)

**基线**（v0.10.1 + v0.8.7 后）：mox 的服务端能力已经覆盖 90% LLM 工作负载（`/v1/chat/completions` SSE、`/v1/completions`、`/v1/messages`、`/v1/embeddings` wire、`/v1/rerank` 端点、`mox convert`、KV budget、增量下载、硬件感知 default）。但 **客户端 GUI 是 0 输入框的空架子**，**`/v1/embeddings` 是 501 stub**，**mlx-swift-lm 已经提供的 VLM/Embedders/多家族 tool parser 一行没接**。v0.11 的目标就是把"已规划但没做"和"上游已经做好但没接"这两类一并清账。

**排序原则**（每条按"用户感知 × 工程量"性价比）：
- **P0**：用户每天都撞上，0 阻碍（基础设施已就位）
- **P1**：用户能感知痛点 / 写了没做，工程量小-中
- **P2**：未来价值，当前不阻塞用户

### P0.1 GUI chat UI（输入框 + 消息流 + tok/s 显示）— 最大单点缺口

**动机**：GUI 现在是 4 个 tab 框架，**ChatsTab 没有输入框**——`AppState.currentConversation` / `messages: [ChatMessage]` / `MoxAPIClient.chat()` 全部就位，**只缺 SwiftUI 视图层调它**。omlx `AppView/Screens/Chats` 12.6k Swift、MTPLX `MTPLXAppHost/Views/Chat` 1.9k+3.4k Swift 是真客户端体量；mox 的 857 行 GUI 是"骨架"不是"应用"。**这是 mox 当前最大的"规划了没做"**。

**做法**：
- `Sources/MoxGUI/MainWindow.swift` — `ChatsTab` 加三件套：
  - **消息流**：`ScrollView` + `LazyVStack` 渲染 `appState.currentConversation?.messages`，user/assistant 气泡样式，timestamp + role label。
  - **输入框**：`TextField` + `Button("Send ⌘↩")` 调 `appState.sendUserMessage(text:)`。
  - **tok/s 实时指示**：assistant 消息尾巴显示 `completion_tokens + tok/s`，从流式 chunk 末段算。
- `Sources/MoxGUI/MoxApp.swift` — `AppState` 加 `func sendUserMessage(text: String) async`：append user message → `client?.chat(modelId:, messages:, stream: true)` → iterate `AsyncStream<String>` → append assistant delta → 末尾把 usage / tok/s 写回 message metadata。
- 流式取消：`client?.cancelChat()`（已就位）+ UI 上 `Button("Stop")` 在流式生成中显示。
- 错误展示：assistant 气泡变红 + 重试按钮。

**验证**：
- 起 daemon + 在 GUI 选 model + 发消息 → assistant 流式出现，文字 + tok/s 正确。
- 切换 conversation（`⌘N`）→ 上下文清空，新消息走新 conversation。
- 取消按钮中途 stop → assistant 消息以 "stopped" 标记结尾。
- 持久化：v0.11 仍 in-memory（v0.12 接 SQLite），刷新窗口会丢。

**不做**：Markdown 渲染（v0.12 再说）；tool call 折叠 UI（§11.3 之后）；代码高亮。

### P0.2 `/v1/embeddings` 实装 + 接入 `MLXEmbedders` 上游 4 个模型

**动机**：v0.8.5 已写 wire 框架但 endpoint 返回 501。mlx-swift-lm 3.31.3 已经 ship `MLXEmbedders` product（4 个模型：Bert、NomicBert、Qwen3-Embedding、Gemma3-Embedding + Pooling）。**0 行业务代码，~500 Swift 即可把 501 → 真 200**。RAG / agent memory 用户已经在撞 501 错误。

**做法**：
- `Sources/MoxServer/Server.swift` — `embeddings` handler 不再返回 501，调 `MLXEmbedders.EmbedderModelContainer`。
- `Sources/MoxCore/ModelRunner.swift` 加 `embeddingModel: EmbedderModelContainer?`，与 LLM `ModelContainer` 互不干扰（不同 `ModelRegistry` slot）。
- `Sources/MoxCore/Embedder.swift` — 把 v0.8 留的 actor 协议 stub 换成 MLXEmbedders 实现。
- `Sources/MoxServer/HTTPRouter.swift` — `/v1/rerank` 同步实装（框架已有，501 → 真 200）。
- `mox-server` 启动时**懒加载** embedding 模型（首次 `/v1/embeddings` 才 load），不预加载，避免拖累 chat 冷启动。

**验证**：
- `mox-server start`，跑 `curl -X POST localhost:11555/v1/embeddings -d '{"model":"mlx-community/bge-small-en-v1.5","input":"hello"}'` → 收到 200 + `data: [{embedding: [...], usage: ...}]`。
- 三种 input 形式：`input: "string"` / `input: ["a","b"]` / `input: [[token_id, ...]]` 全部支持（OpenAI 规范）。

### P0.3 `mox pull` 自动量化 `--mode` 暴露

**动机**：`mox convert --mode mxfp4` 已能用，但 `mox pull` 自动量化路径（v0.9.0 §"pull auto-quantize"）**硬编码 `.affine`**。用户在 64 GB+ 机器上 pull 14B+ bf16 模型默认还是 4-bit affine 路径，不走更精确的 mxfp8。

**做法**：
- `Sources/MoxCLI/main.swift` — `handlePull` 加 `--quant-mode affine|mxfp4|mxfp8|nvfp4` flag（默认仍 `affine`），透传到 `maybeAutoQuantize`。
- `Sources/MoxConvertCore/MoxQuant.swift` — `QuantizationOptions.mode` 已经在签名里，**0 行 backend 改动**，只改 CLI 默认值。
- `CHANGELOG` 加 `mox pull --quant-mode`。

**验证**：`mox pull Qwen/Qwen2.5-7B-Instruct --quant-mode mxfp4` → pull 完 sibling `<id>-4bit-mxfp4/` 目录 + manifest `sourceFormat = "mlx-4bit-mxfp4"`。

**不做**：把默认改 `mxfp4`（affine 仍是生态主流，更稳）。

### P1.1 `mox doctor` — 安装 / 集成诊断

**动机**：omlx `diagnose_command`、MTPLX `doctor --deep` 都有。mox 现在的"安装挂了"反馈链是 `mox-server start` → 失败 → 一行 `Error: ...` → 用户 Google。**`mox doctor` 把这条反馈链改成自动报告**。

**做法**：
- 新增 `mox doctor` 子命令（`Sources/MoxCLI/main.swift` 加 `handleDoctor`）。
- 5 步检查：
  1. **System**：macOS 版本、Apple Silicon 型号、`uname -m`。
  2. **MLX**：检查 `mlx-swift` / `mlx-swift-lm` 是否能 import（编译时已 OK，runtime 探一次）。
  3. **Model dir**：`~/.mox/` 路径可写、目录树结构、`mox.json` 解析无错。
  4. **Daemon**：`launchctl list | grep mox-server` / `mox-server status` / `curl /health`。
  5. **Network**：HF / ModelScope 端点连通性（HEAD `/`）。
- 输出 `OK` / `WARN` / `FAIL` 三色 + 修复建议。
- `--json` flag 给 GUI 消费。

**验证**：

**不做**：自动修复（auto-fix）——只报告，让用户决策。

### P1.2 `/v1/models/{id}/load|unload` endpoint

**动机**：v0.8.6 `ModelRegistry` actor + LRU 已就位，但**没有 HTTP 端点暴露**。omlx `/v1/models/{id}/load`、`/v1/models/{id}/unload` 都有；多模型管理场景下 CLI `mox run` 切模型要重启 daemon，**HTTP 端点让 GUI 一键切**。

**做法**：
- `Sources/MoxServer/HTTPRouter.swift` 加 2 行：`POST /v1/models/{id}/load` + `POST /v1/models/{id}/unload`。
- handler 在 `MoxServer.Server.swift`：
  - `load`：调 `ModelRegistry.register(id:, weightsBytes:)` + `ModelRunner.loadModel(id:)`；已加载返回 200 + `{"id":..., "loaded": true}`；不存在的 id 返回 404。
  - `unload`：调 `ModelRunner.unloadModel(id:)` + `ModelRegistry.evict(id:)`。
- 配合 GUI ModelsTab 的每行加 `Load` / `Unload` 按钮（一行 SwiftUI 改动）。

**验证**：

### P1.3 `stream_options.include_usage` 完整实现（§10.4 前移）

**动机**：原 ROADMAP §10.4 规划 v1.0，**v0.11 前移**——Claude Code 等 agent 客户端已用 stream + 算 cost 是真实痛点。`MoxServer` 现在发 SSE 但 usage 字段不填。

**做法**：
- `Sources/MoxServer/Server.swift` — `chatCompletionsStream` handler 末尾：模型返回 final usage → 多发一个 chunk `{"id":"...","object":"chat.completion.chunk","choices":[],"usage":{...}}` + `data: [DONE]\n\n`。

**验证**：

### P1.4 Reasoning / thinking budget（§9.3 实装）

**动机**：Qwen3、DeepSeek-R1、GLM5、Claude 都出 thinking。GUI 用户期望默认折叠 thinking 只显示 answer。**原 §9.3 一直未做**。

**做法**：
- `MoxShared.ChatCompletionChoice` 加 `reasoning_content: String?`（OpenAI 兼容扩展字段）。

**验证**：

### P2.1 MLXEmbedders 之外的 4 个 embedding 模型管理

**动机**：P0.2 实现了 `/v1/embeddings`，但需要 model pull 流程。当前 `mox pull` 只支持 LLM。

**做法**：
- `Sources/MoxCore/ModelManager.swift` — `pullModel` 加 `kind: .llm | .embedder` 区分；embedder 默认 source 用 `mlx-community` 拉 `bge-*` / `nomic-embed-*` / `qwen3-embedding-*`。

### P2.2 MLXVLM 16 个 VLM 模型接入（vision 多模态）

**动机**：mlx-swift-lm 3.31.3 提供 16 个 VLM（Qwen3-VL、Qwen2.5-VL、Gemma3/4、SmolVLM2、Idefics3、Paligemma、FastVLM...）。**0 行业务代码接入 = 当前最大的"上游已做好没接"**。

**做法**：
- `Sources/MoxCore/ModelRunner.swift` — `loadModel` 探测是 LLM 还是 VLM（`ModelConfiguration.modelType` 字段或目录里 `preprocessor_config.json` 存在）。

**验证**：

### P2.3 Tool parser 改用 mlx-swift-lm 上游 6 个

**动机**：mox 自写 2 个 tool parser（XML + Generic），mlx-swift-lm 已有 8 个（Llama3、Mistral、GLM4、Gemma、KimiK2、Pythonic、JSON、XML）—— 上游 6 个 mox 没接，agent 兼容性受损。

**做法**：
- `Sources/MoxShared/GenericToolCallParser.swift` 保留作为默认 fallback。

**验证**：

### P2.4 持久化对话历史（SQLite）

**动机**：GUI chat UI（v0.11 P0.1）刷新窗口丢上下文。`AppState` 现在 in-memory `currentConversation: Conversation?`，死亡即丢。

**做法**：
- `Sources/MoxCore/ConversationStore.swift` — actor over SQLite（GRDB 或自写 `sqlite3` 绑定）。

**不做**：多设备 sync；端到端加密（家用工具定位不需要）。

### P2.5 v0.11 留观 — 上游 API 不稳定 / 不主动造



## §11 mlx-swift-lm 上游能力清单（决策参考）

**当前 mox 用的版本**：mlx-swift 0.31.6 + mlx-swift-lm 3.31.3（package resolved）。

| 上游 product | 提供什么 | mox 消费？ | 备注 |
|--------------|---------|-----------|------|
| `MLX` (核心) | 数组 + Metal backend | ✅ 全部 | — |
| `MLXNN` (层) | Linear / LayerNorm / quantize API | ✅ 全部 | — |
| `MLXLLM` (LLM) | 25+ 模型家族 + `LLMModel` + `loadModelContainer` | ✅ 全部 | 主力 |
| `MLXVLM` (视觉) | **16 个 VLM 模型**（Qwen3-VL、Qwen2.5-VL、Gemma3/4、Pixtral、SmolVLM2、Mistral3、Idefics3、Paligemma、FastVLM、LFM2VL、Qwen35、Qwen35MoE、Qwen2VL、GlmOcr、QwenVL） | ❌ **0 行消费** | **P2.2 接入** |
| `MLXLMCommon` (共享) | `ChatSession`、`UserInput`、`ModelContainer`、`Tool/Parsers/`（8 个） | ⚠️ 部分：`ModelContainer` ✅，**`Tool/Parsers/` 仅自写 fallback** | P2.3 |
| `MLXEmbedders` (embedding) | **4 个模型**（Bert、NomicBert、Qwen3-Embedding、Gemma3-Embedding）+ Pooling | ❌ **0 行消费** | **P0.2 接入** |
| `MLXHuggingFace` (HF 集成) | tokenizer / downloader | ✅ 全部 | — |
| `Tokenizers` | HF tokenizer Swift 绑定 | ✅ 全部 | — |
| `QuantizationMode { affine, mxfp4, mxfp8, nvfp4 }` | 4 种 quant mode | ⚠️ `mox convert` 已暴露 3 种，**`mox pull` 自动量化仍硬编码 affine** | P0.3 |
| `Speculative decoding` | **mlx-swift-lm 没有此 API** | — | **明确不做**（mox 不造 kernel） |
| `MTP / multi-token prediction` | **mlx-swift-lm 没有此 API** | — | **明确不做** |
| `BatchGenerator`（vLLM-style 连续批处理） | **mlx-swift-lm 3.31.3 仍无 Swift 绑定** | — | §9.2 推到等上游 |
| `KVCache 引用访问`（prefix cache 关键） | **mlx-swift-lm 没暴露底层引用** | — | §9.1 推到 v0.12+ |

**决策原则**：凡是 mlx-swift-lm 已经做的，**mox 直接调上游 API，不重写**。凡是上游没做的，**不造**（避免 DESIGN §0 偏离）。这一原则下：



## v1.0 — 多 tier + 周边工具

### 10.1 Paged SSD cold tier ⏳ 等 §9.1 prefix cache（v0.12+）

**动机**：omlx 把 SSD cold tier 当核心卖点，long session 跨 restart 恢复 prefix cache。

**做法**：在 9.1 PrefixCache 基础上加 SSD spillover：

**验证**：80% 内存占用下，session 重启后第一次请求命中冷盘 block，prefill 加速。

**不做**：分布式 KV 缓存（无场景）。

### 10.2 Web admin dashboard ⏳ 等 v0.11 GUI chat UI 稳定

**动机**：omlx `/admin` 完整 Web UI 抢了很多"非技术用户"。**注意**：mox 有 SwiftUI GUI，这个 dashboard 只是补充，给远程 / headless 场景用。

**做法**：
- `/admin` 静态 HTML + 最小 JS（vanilla，不引框架），CDN 自托管或 vendored。
- 实时数据用 Server-Sent Events 推（不引 WebSocket）。
- 功能：模型列表 + 加载状态、实时 tok/s 日志、配置编辑、保存回 `~/.mox/config.json`。
- GUI 用户继续用 SwiftUI，不重复造。

**验证**：浏览器打开 `/admin` 看到模型列表；改端口保存 config 后 `mox-server status` 显示新端口。

**不做**：把 `/admin` 做成完全功能 GUI（chat、benchmark 等）—— 那是 SwiftUI 的事。

### 10.3 Benchmark runner ⏳ 等 §9.1 prefix cache（v0.12+）才有意义

**动机**：omlx 一键 PP/TG + partial prefix cache 测试；MTPLX 内置 AIME benchmark。**对用户选模型、调参有直接价值。**

**做法**：
- `mox bench --model <id> --prompt-tokens 512 --gen-tokens 128`：跑 N 次取 tok/s 中位数。
- `mox bench --prefix-hit`：测试 prefix cache 命中后的 prefill 加速比。
- 输出 table 到 stdout + JSON `--json`。

**验证**：相同硬件同模型，跟 omlx/MTPLX 公开 benchmark 数对照 ±10%。

**不做**：AIME / MMLU 这类任务评测（学术评测，工具定位不需要）。

### 10.4 OpenAI `stream_options.include_usage` 完整实现 — **前移到 v0.11 §P1.3**（Claude Code 用户痛点）

---

## 明确不学

- **Speculative decoding Metal kernel 优化**：mlx-swift-lm 0.31.6 / 3.31.3 都没暴露此 API；mox 不写自研 kernel = 违反 DESIGN §0。v0.11 §P2.5 显式不做。
- **多 Mac 集群（omlx Ring/JACCL）**：复杂度炸裂，市场小。
- **MTPLX 多家族 patch 文件**（`deepseek_v4_*.py` × N）：Python 缺类型的 namespace 退化，Swift enum 一行解决。
- **MTPLX 多档 scheduler_mode**（serial / cooperative / ar_batch / mtp_batch）：Swift actor 模型不需要 ownership contract 这种 GIL 妥协。
- **MTPLX `sustained` / `turbo` / `sustained_max` 等 profile 抽象**：v0.9 硬件感知 default 已经覆盖 90% 场景，余下让用户配置。
- **omlx settings.py 67k 行**：Python 单文件膨胀的反面教材，Swift module 拆分避免。
- **MTPLX 强制 attribution clause**：mox MIT 更友好。

---

## 保留的 Swift 优势

- actor 隔离（编译期并发安全，omlx/MTPLX 靠 Lock + 文档）
- Sendable 强制（跨模块类型 contract）
- 单一二进制（Mox.app 无 PyInstaller venvstacks 200MB Python 层）
- 错误显式化（`throws` 强制 caller 决策，Python 异常可被忽略）
- strict concurrency（编译期拒并发 bug，不靠 runtime 测试）

不为对齐竞品丢这些。
---

## 下次会话从这里开始（v0.11 P0 候选，2026-09）

v0.10.1 已交付（4 commits / +803 / -54 lines / 193 tests pass）。下次会话的 v0.11 P0 候选按"用户感知 × 工程量"排：

**P0**（每天都撞上，0 阻碍）：
- **P0.1 GUI chat UI** — `Sources/MoxGUI/MainWindow.swift` `ChatsTab` 加输入框 + 消息流 + tok/s 实时显示；`Sources/MoxGUI/MoxApp.swift` `AppState` 加 `sendUserMessage(text:)` 流式调 `MoxAPIClient.chat()`。**最大单点缺口**。
- **P0.2 `/v1/embeddings` 实装** — `Sources/MoxServer/Server.swift` 把 501 stub 换成 `MLXEmbedders.EmbedderModelContainer` 调用；`Sources/MoxCore/Embedder.swift` actor 协议换成 MLXEmbedders 实现；`/v1/rerank` 同步实装。mlx-swift-lm 3.31.3 已 ship 4 embedding 模型，0 行业务代码即可从 501 → 200。
- **P0.3 `mox pull --quant-mode` flag** — `Sources/MoxCLI/main.swift` `handlePull` 加 `--quant-mode affine|mxfp4|mxfp8|nvfp4` 透传；`mox convert --mode` 已有，pull 路径仅 0 后端改动。

**P1**（用户能感知痛点）：
- **P1.1 `mox doctor`** — `Sources/MoxCLI/main.swift` 新增 `handleDoctor`；5 步检查（System / MLX / model dir / daemon / network）+ `--json` flag。
- **P1.2 `/v1/models/{id}/load|unload` endpoint** — `Sources/MoxServer/HTTPRouter.swift` 加 2 行路由；`Sources/MoxServer/Server.swift` handler 调现有 `ModelRegistry` + `ModelRunner`。v0.8.6 基础设施已就位，~100 Swift。
- **P1.3 `stream_options.include_usage`**（§10.4 前移）— `Sources/MoxServer/Server.swift` `chatCompletionsStream` 末尾多发 `{"choices":[],"usage":{...}}` chunk。~200 Swift。
- **P1.4 Reasoning / thinking budget**（§9.3 实装）— `MoxShared.ChatCompletionChoice.reasoning_content` 字段 + GUI 折叠 toggle。~1k Swift。

**P2**（v0.12+ 再说）：
- **P2.1-2.4** — embedding 模型管理 / MLXVLM 16 个 VLM 接入 / 用 mlx-swift-lm 上游 6 个 tool parser 替自写 / 持久化对话（SQLite）。

**P2.5 明确不做的**：Speculative decoding（mlx-swift-lm 没 API，违反 DESIGN §0）、Paged SSD cold tier、Cluster 分布式、MTP（mlx-swift-lm 没 API）。

**进入 v0.11 实施前先决条件**：
- ROADMAP §11 上游能力清单的"mox 消费"列已经从 ❌ 改为 P0/P1/P2 项。
- 决策 P0 是否要在 v0.10.2 hotfix 之后立刻做（避免空挡）。
