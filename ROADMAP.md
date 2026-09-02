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

---

## v0.8 — 工具调用 + 模型路由 ✅ v0.8.0 已交付 (2026-08)

### 8.1 Tool calling parser registry ✅ (基础版 — 单 XML parser 覆盖 Qwen/Llama/Mistral/DeepSeek)

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

### 8.3 多 model 实例 + 内存预算 — 推迟至 v0.9

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

### 8.4 增量下载 ✅ (diff 引擎 + `mox list --check` 完成；`mox update` 实际下载推迟至 v0.9)

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

### 8.5 `/v1/embeddings` 框架 ✅ (wire 完整 + 501 Not Implemented)

**动机**：MTPLX 把 embedding/rerank 同 daemon 跑，agent memory 不用起第二个 server。**注意：mlx-swift 生态 embedding 支持还在演进，框架先做、模型后接。**

**做法**：
- `/v1/embeddings` + `/v1/rerank` endpoint 框架，按 OpenAI 规范定义 Request/Response 类型（在 `MoxShared`）。
- `MoxCore.Embedder` actor 协议接口；v0.8 默认返回 `501 Not Implemented` + 清晰 roadmap 提示。
- 文档说清楚 v0.9+ 接 mlx-swift embedding 时只需要换实现。

**验证**：endpoint 形态正确（Pydantic 客户端能 introspect Request schema），返回 501 时 body 是结构化错误。

**不做**：v0.8 内任何实际 embedding 计算。

---

## v0.9 — 格式转换 + KV 缓存 + 性能

### 9.0 `mox convert` + `mox re-quantize` CLI

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

### 9.1 Prefix hash + block sharing in RAM

**动机**：长 agent session 里 system prompt + 工具描述 + 前几轮对话几乎不变，prefix cache 命中省一次完整 prefill。omlx block hash + CoW 设计的核心动机；MTPLX SessionBank warm prefix 是同思路。

**做法**：
- 新建 `MoxCore.PrefixCache` actor：`(prefixTokenHash → KVCacheHandle)` 表。
- hash 算法：rolling hash over token id 序列，每 256 token 算一个 block hash（omlx block size）。
- 请求进入时 tokenize → 算前缀 hash → 命中块数 → 只对未命中部分 prefill。
- mlx-swift-lm 的 KVCache 如果不暴露底层引用，**就在 MoxCore 层维护一个 `Token[] → Array` 的引用映射**，命中时把已有 arrays `mx.array` 引用塞回去（mx 是 reference-counted，可行）。
- 单请求内 cache miss 也走 prefix cache 路径（多轮同一 session 加速）。

**验证**：
- Benchmark：同一 system prompt + 工具描述（~500 tokens），第二次发起同 prompt 请求，prefill 时间降到 < 20%。
- 不同前缀（不同 system prompt）不会误命中。

**不做**：SSD tier（v1.0+）；CoW 的 CoW（mlx-swift KV 已是 immutable array，无需 CoW）。

### 9.2 Continuous batching 接入准备

**动机**：omlx 抄 vLLM scheduler 跑 mlx-lm `BatchGenerator`，多请求并发时吞吐翻倍。当前 mox 一次一个请求独占 GPU。

**做法**：
- 短期：MoxServer 加进程级 FIFO 队列，`/v1/chat/completions` 多请求按到达顺序串行处理（single runner + queue），单进程多 client 不再直接 reject。
- 中期：等 mlx-swift-lm 出 BatchGenerator 绑定（跟踪上游 issue），抄 omlx scheduler 的 request lifecycle（`waiting → running → finished`）做成 Swift actor。

**验证**：
- 短期：3 个并发 curl，第三个不是立刻 503 而是排队等到第一个结束。
- 中期：BatchedEngine 真接入后对比 single runner 吞吐（tok/s 总和）。

**不做**：scheduler 调度策略（FCFS / SJF / priority）—— 等 batch 真接入了再说。

### 9.3 Reasoning / thinking budget

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

### 9.4 硬件感知 default model

**动机**：MTPLX 按 M1/M2/M3/M4/M5 + 内存选推荐模型，32 GB 以下推荐 9B、64 GB+ 推荐 27B。

**做法**：
- `MoxCore.HardwareClassifier`：`uname -m` + `sysctl hw.optional.arm64` + `host_statistics64` 拿内存 + `sysctl machdep.cpu.brand_string` 解析 generation。
- `MoxCore.DefaultModelSuggester`：按 (generation, totalRAM) → 推荐 model id + 内存预算 + 提示。
- `mox -m` 不带参数时打印推荐 + 让用户确认，不强推。

**验证**：
- 32 GB Mac mini 跑 `mox -m` 推荐 9B + 提示内存紧。
- 96 GB Mac Studio 推荐 27B + 提示可考虑 35B MoE。

**不做**：自己维护一份"verified model catalog"——MTPLX 闭源前提的产物，mox 不做商业 curated list。

---

## v1.0 — 多 tier + 周边工具

### 10.1 Paged SSD cold tier

**动机**：omlx 把 SSD cold tier 当核心卖点，long session 跨 restart 恢复 prefix cache。

**做法**：在 9.1 PrefixCache 基础上加 SSD spillover：RAM 预算满时，evicted blocks 写 `~/.mox/cache/blocks/<hash>.safetensors`；下次请求命中 hash 时 mmap 读回 RAM。

**验证**：80% 内存占用下，session 重启后第一次请求命中冷盘 block，prefill 加速。

**不做**：分布式 KV 缓存（无场景）。

### 10.2 Web admin dashboard

**动机**：omlx `/admin` 完整 Web UI 抢了很多"非技术用户"。**注意**：mox 有 SwiftUI GUI，这个 dashboard 只是补充，给远程 / headless 场景用。

**做法**：
- `/admin` 静态 HTML + 最小 JS（vanilla，不引框架），CDN 自托管或 vendored。
- 实时数据用 Server-Sent Events 推（不引 WebSocket）。
- 功能：模型列表 + 加载状态、实时 tok/s 日志、配置编辑、保存回 `~/.mox/config.json`。
- GUI 用户继续用 SwiftUI，不重复造。

**验证**：浏览器打开 `/admin` 看到模型列表；改端口保存 config 后 `mox-server status` 显示新端口。

**不做**：把 `/admin` 做成完全功能 GUI（chat、benchmark 等）—— 那是 SwiftUI 的事。

### 10.3 Benchmark runner

**动机**：omlx 一键 PP/TG + partial prefix cache 测试；MTPLX 内置 AIME benchmark。**对用户选模型、调参有直接价值。**

**做法**：
- `mox bench --model <id> --prompt-tokens 512 --gen-tokens 128`：跑 N 次取 tok/s 中位数。
- `mox bench --prefix-hit`：测试 prefix cache 命中后的 prefill 加速比。
- 输出 table 到 stdout + JSON `--json`。

**验证**：相同硬件同模型，跟 omlx/MTPLX 公开 benchmark 数对照 ±10%。

**不做**：AIME / MMLU 这类任务评测（学术评测，工具定位不需要）。

### 10.4 OpenAI `stream_options.include_usage` 完整实现

**动机**：Claude Code 等客户端需要 usage chunk 来算成本。

**做法**：在 7.1 SSE 路径里加 usage 字段发送逻辑。`completion_tokens` / `prompt_tokens` / `total_tokens` 从 `ModelRunner` 拿。

**验证**：客户端收到 usage 字段不为 null；非流式请求也带 usage。

**不做**：cost 计算（无价格数据源）。

---

## 明确不学

- **Speculative decoding Metal kernel 优化**：不在 Swift 生态内可控，等上游或外包。
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

## 下次会话从这里开始（v0.9.0 续做 #2）

**已完成**（v0.9.0 第一波）：
- `Sources/MoxConvertCore/MoxQuant.swift` —— `MoxQuant.quantize(sourceDirectory:options:)` 核心 pipeline 实装。
- `Sources/MoxCLI/main.swift` —— `mox convert` / `mox re-quantize` / `requantize` 三个 dispatch + `handleConvert` + `handleRequantize` + `printConvertHelp` + `directorySize` 帮助函数；`printHelp` 加新命令和示例。
- `CHANGELOG.md` v0.9.0 "Added (shipped)" 收 CLI 两条。
- `swift build` + `swift test` 全绿（132 tests pass）。

**v0.9.0 续做 #2 目标**：补 §9.0 步骤 5/6 —— (a) 集成测试覆盖 `MoxQuant.quantize` 全流程；(b) `mox pull` 后置钩子自动把 bf16/fp16/fp32 转 4-bit，manifest 写明量化 provenance。这两块收掉后，v0.9.0 才能 tag。

**具体步骤**（按顺序做，每个 ~30 分钟）：

1. **`Tests/MoxCoreTests/MoxQuantIntegrationTests.swift`** —— 临时目录 + 假 `config.json`（model_type=torch_dtype=bfloat16）+ dummy `.safetensors`，调 `MoxQuant.quantize(...)` 跑全流程。期望：
   - 真实 MLX model container 加载会失败（缺 hidden_size 等真实字段），但失败必须是**结构化的 loader 错误**，不是 panic / trap。
   - 验证 `QuantizationOptions.outputDirectory` 目录被创建。
   - 这是 CI 烟雾，不是真量化产物验证（真产需要真权重）。
2. **`Sources/MoxConvertCore/MoxQuant.swift`** —— 让 `MoxQuant.quantize` 写入 output 目录时，**在 `config.json` 里塞入 `quantization_config`** 字段（`{"group_size": ..., "bits": ...}`）。这样：
   - 下次 `MoxConverter.inspect(at:)` 在该目录上能正确归类为 `.mlxQuantized`。
   - 不影响 mlx-swift-lm 加载（上游靠 weights 里的 `.scales` 判定，不是 config.json 字段），但**与生态约定一致**。
3. **`Sources/MoxCLI/main.swift` 的 `handlePull`** —— pull 成功后：
   - 调 `MoxConverter().inspect(at: destinationDir)`。
   - 若 `.hfPrecision(let dtype)` → 默认 4-bit/64/affine 触发 `MoxQuant.quantize(...)` 到 sibling `<dir>-4bit/`；更新 `ModelInfo.path` 指 quantized 目录；改写 manifest 的 `sourceFormat = "mlx-<bits>bit-<mode>"`、`quantization = MoxQuantizationInfo(...)`。
   - 若 `.mlxQuantized` → 跳过，**已经 quantized 直接用**。
   - 若 `.unknown` → 不动，保留 v0.5 行为（manifest 里写 "unknown(...)"）。
   - **分离关注点**：`handlePull` 串两步，**不在 `ModelManager.pullModel` 内部嵌套**。原因：`pullModel` 是 actor 内的纯 I/O，convert 是重计算（内存密集），挂上会让 model manager 难测、难 retry。
4. **新 flag**：`mox pull --no-auto-quantize` —— 跳过自动 convert，给想要手动控制的人留口子（默认开，opt-out）。
5. **CHANGELOG v0.9.0**：
   - "Added (shipped)" 加 `mox pull --no-auto-quantize`、集成测试条目。
   - "Pending" 段删掉（v0.9.0 已全收）。
   - 顶部版本标题从 `(in progress)` 改 `(2026-09)`，或者干脆加 `v0.9.0` tag 再写 release notes。
6. **commit + push**。

**关键文件**：
- `Sources/MoxConvertCore/MoxQuant.swift` —— 写入 `config.json` 增量。
- `Sources/MoxCLI/main.swift` —— `handlePull` 增量 + `--no-auto-quantize` 解析。
- `Sources/MoxCore/ModelManager.swift` —— **不改**。`pullModel` 边界不变；convert 在 `handlePull` 这一层串。
- `Sources/MoxShared/Models.swift` —— `ModelManifest.quantization: MoxQuantizationInfo?` 字段已经存在，直接复用。`sourceFormat` 是 String 不动，新值 `mlx-4bit-affine` 写进去即可。
- `Tests/MoxCoreTests/MoxQuantIntegrationTests.swift` —— 新文件。

**注意点**：
- **不要在 `pullModel` 内部调 `MoxQuant.quantize`** —— 那是 actor 内，convert 是重计算 + 大内存分配，把 actor 卡住会让所有并发的 `listModels` / `modelInfo` 都阻塞。`handlePull` 是 `async throws` 的函数，串两步最自然。
- `MoxQuant.quantize` 的输入是 `sourceDirectory`，写 `config.json` 之前要小心：源目录可能是同一个用户目录（`mox convert` 时），也可能不是（`mox pull` 时源 = pull 出的目录，输出 = `<dir>-4bit/` sibling）。**只写 outputDirectory 的 config.json，不动 sourceDirectory**。
- bf16 → 4-bit 默认触发 = 用户可能不想要（16 GB 内存紧的机器上转 7B 可能挂）。但 `mox pull` 文档默认就是 "给你一个能用的模型"，不量化就不能用 —— 默认开是合理的，opt-out 已经设计。
- v0.9 不做：HF id 触发 convert 的路径（即直接 `mox convert Qwen/X` 不经过 `mox pull`，要解析 HF 重定向等）；re-quantize 的 bit-width 检测（要读 weights metadata）。

**验证 checklist**（完成后 grep）：
- [ ] `MoxQuantIntegrationTests` 在 `Tests/MoxCoreTests/` 下，3+ 测试
- [ ] `mox convert` 写出的目录的 `config.json` 含 `quantization_config`
- [ ] `mox pull Qwen/Qwen2.5-0.5B-Instruct --source huggingface`（用 tiny fixture 或者断网 mock）后，`destinationDir` 的 `mox.json` `sourceFormat = "mlx-4bit-affine"`，且 sibling `<id>-4bit/` 存在 model.safetensors
- [ ] `mox pull --no-auto-quantize` 不触发 convert，manifest 保留 `huggingface-bfloat16`
- [ ] CHANGELOG v0.9.0 "Pending" 段为空，顶部日期填上
- [ ] 132+3 = 135+ 测试全过
