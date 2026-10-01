# 本机推理 API

先运行 `mox serve` 或打开 App；公开 API 默认关闭，通过 App“本机 API”或 `mox api enable` 开启。`mox api status` 返回动态地址，`mox api key` 显示独立 Keychain 密钥。将地址（不带 `/v1`）填入 `$MOX_API_URL`，密钥填入 `$MOX_API_KEY`。客户端配置在服务重启后刷新；key 重置使旧 key 失效。

```sh
curl "$MOX_API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MOX_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"my-model","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'

curl "$MOX_API_URL/v1/messages" \
  -H "x-api-key: $MOX_API_KEY" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' \
  -d '{"model":"my-model","messages":[{"role":"user","content":"你好"}],"max_tokens":64}'
```

OpenAI SDK 的 base_url 使用 `$MOX_API_URL/v1`；Anthropic SDK base_url 使用 `$MOX_API_URL`，并传 api_key。只支持下述子集，不保证需要 Responses 等接口的任意 agent 可用。`GET /v1/models` 列出可请求的安装 alias；`model` 接受 alias 或安装 UUID，不是文件路径。公共 `/health` 只提供探活。

两个 listener 仅 `127.0.0.1`；公开 key 不可调用私有 `/mox/v1/*`，管理 token 不可作为公开 key。拒绝非空 Origin/浏览器跨站请求，无宽松 CORS。无 LAN、服务端工具执行或公共请求自动写 GUI 历史。

## 协议契约

下列为 **Mox 0.1 支持子集**，不是声称两家 API 的完整实现。解析器对已知但不支持的语义字段和未知非空字段返回 400，指出安全的字段路径；不得用宽松 Decodable 静默丢弃。允许标准 SDK 会附带但不改变语义的空/默认字段，逐项列入 fixtures；不得以“忽略所有 extra”实现。请求 JSON 深度、字符串、工具数量与 schema 大小设命名上限，16 MiB body 上限在聚合前执行；输入仍受 Core 1 MiB 原文、8192 token、模型 context 与资源预算限制。精确值由所属模块单处定义，测试记录。

### OpenAI Chat Completions

- 请求：`model` 为本服务已安装 alias 或精确安装标识；`messages` 依原顺序接收 `system`、`user`、`assistant` 的文本字符串或纯文本块，以及 `assistant.tool_calls` 和 `tool` 的 `tool_call_id` 文本结果。`developer`、`function` 旧角色、`name`、图片/音频/视频、refusal、未识别块拒绝。工具调用必须由紧邻的上一 assistant 轮次定义，ID 唯一，多个结果可用连续 `tool` 消息逐一匹配；未收齐前不得插入无关 user/assistant/system 消息，不能丢弃缺失/多余结果。服务不自动补历史。
- 接收 `stream`（默认 false）、`temperature`、`top_p`、`max_tokens`、`stop`（字符串或有限字符串数组）、`tools`（仅 `type:function` 的 name/description/JSON object parameters）、`tool_choice` 的 `none`/`auto`，`stream_options.include_usage`。`n` 仅 1，`parallel_tool_calls` 仅 false，`response_format` 仅缺省或 `text`；其他值拒绝。`required`、指定函数、strict schema、`seed`、`logprobs`、penalties、`max_completion_tokens`、prediction、modalities、audio、service_tier、store、metadata 等首版拒绝。缺省 `tool_choice`：无工具为 none，有工具为 auto。`none` 不得生成结构化工具调用；auto 仅在模型能力经验证时接受，否则 400 `unsupported_input`。这里的工具选择限制是明确的 0.1 产品边界，后续若要支持强制选择须先证明运行时可执行该语义，不能只靠提示词伪装。
- 非流式成功：`chat.completion`、稳定本次 ID、实际模型、单 choice 的 assistant（文本或 `tool_calls`），`finish_reason` 为 `stop`/`length`/`tool_calls`，`usage.prompt_tokens`/`completion_tokens`/`total_tokens` 来自已执行推理的真实计数。没有可证计数时失败，不填估算或零。无工具调用时 `tool_calls` 不出现或为 null，遵循 SDK 解码实测。
- 流式：`text/event-stream` 的 `data:` ChatCompletionChunk；首块 `delta.role=assistant`；文本 delta 保持 UTF-8 顺序；工具按 `index`、稳定 `id`、function `name` 起始，再发可拼接的 `function.arguments` JSON 字符串分片，末块 finish_reason；末尾 `data: [DONE]`。`include_usage=true` 时在 DONE 前发 `choices:[]` 的最终 usage chunk，先前 chunk usage 为 null/省略；false 时不承诺末尾 usage chunk。ID/model/created 在同一响应一致。工具参数只有通过完整 JSON 与 schema 基本校验后才可标 tool_calls 终态；不把尚未确认的模型文字伪装为已完成调用。部分流失败按下文错误处理。

### Anthropic Messages

- 必须要求 `anthropic-version: 2023-06-01`；`x-api-key` 单独校验，`anthropic-beta` 非空一律拒绝，避免虚假 beta 语义。`model` 同上；`max_tokens` 必填且为正。`system` 接收字符串或纯文本块；`messages` 按原顺序接收 user/assistant 的文本块，assistant `tool_use`（id/name/input JSON object），user `tool_result`（tool_use_id/纯文本/is_error）。不接收图片、文档、thinking、server tools、cache_control、citations 或其它内容块。多个 tool_result 必须在紧随调用的同一 user 消息中收齐，可与文本块混排；不得跨越无关轮次，保留块顺序与错误标志。
- 接收 `stream`、`temperature`、`top_p`、`stop_sequences`、`tools`（仅客户端自定义 name/description/input_schema JSON object）、`tool_choice` 的 `auto`/`none`。`any`、指定 tool、`disable_parallel_tool_use` 为 true、fine-grained streaming、JSON/结构化输出、`top_k`、`metadata`、`service_tier` 等拒绝；缺省有工具时 auto、否则 none。文本与工具可混合且多个 tool_use 块按生成顺序输出。无工具能力模型带工具请求明确拒绝。
- 非流式：`type:message`、assistant role、有序 `content` 文本/tool_use 块、`stop_reason` 为 `end_turn`/`max_tokens`/`stop_sequence`/`tool_use`；`usage.input_tokens`/`output_tokens` 为真实计数。没有缓存 token 时不伪造 cache 统计。`stop_sequence` 返回实际命中的序列，否则 null。
- 流式：严格按 `message_start` → 每块 `content_block_start`、零或多个 `content_block_delta`、`content_block_stop` → `message_delta`（最终 stop_reason 与累计 usage）→ `message_stop`。文本用 `text_delta`；工具输入用 `input_json_delta.partial_json`，块开始携带 id/name 和空 input；各 index 稳定且拼接后是合法 JSON object。`message_start.usage` 包含真实 input token，最终 message_delta 含真实累计 output token。可发 ping；不能把 OpenAI `[DONE]` 发到 Anthropic 流。

### 共同生成语义与错误

- 参数在准入前解析并冻结；`stop`/`stop_sequences` 必须真正在生成边界生效，跨 token/Unicode 分片正确，命中序列不出现在用户文本；它与自然 EOS、长度耗尽、工具调用分别映射停止原因。模型特殊 token 或未知上游停止原因不得凭猜测映射为成功。取消不返回伪造的 `stop`/`end_turn`，客户端主动断连则取消并等待后端及 lease 释放；若连接仍在，使用协议错误终止流。
- 错误在 headers 前给协议 JSON：OpenAI `error:{message,type,param,code}`，Anthropic `type:error,error:{type,message},request_id`。分类：400 格式/不支持，401 凭据，404 模型，409 状态冲突，413 大小，429 队列，503 不可用，500 意外错误；资源不足用稳定 `resource_exhausted` code 并取 503。认证检查早于模型信息泄露。SSE headers 后失败发相应协议的 `error` 事件/错误 data 并关闭，绝不再写第二个 HTTP 响应、成功终态或 DONE；SDK 可能将其解释为异常或流中断，测试必须核对。request ID 可用于脱敏诊断关联。
- 每请求有服务拥有的 task、单个 Core GenerationHandle 和唯一终态；真实 HTTP 写入 await 背压，写入超时/断连取消并等待；客户端长时间不读须有有界队列与期限，不能让 GPU 或内存无限积压。正常结束 flush/end；服务关闭 drain 所有在途任务。公共请求默认不记录正文、参数、工具输入/结果、API key、Authorization、敏感 URL。日志只留协议、阶段、时长、稳定错误码、request/model 安全标识和计数。失败路径能在 GUI 诊断中定位。
- 对未读完 body 就能拒绝的请求，先写有界协议错误并关闭连接，不等待客户端继续上传；GET 带 body 明确拒绝。已鉴权的请求体读取有绝对期限，空闲 HTTP/1 连接也有限期；超过 16 MiB 的声明长度和聚合中超限都释放连接配额。用未终止 chunked 真 socket 测试 401/403/413、连接关闭及后续正常请求。


## 工具能力和边界

工具必须由客户端执行，再显式带完整历史和相同调用 ID 请求下一轮。Mox 不执行函数、文件或网络工具。支持 auto/none，不提供 required/any 或指定函数强制调用；未知语义明确拒绝。

当前经验证的工具产物为受管 `mlx-community/Qwen3-0.6B-4bit`，HF revision `73e3e38d981303bc594367cd910ea6eb48349da8`，还必须匹配权重与 tokenizer 摘要。仅 model_type、模型卡或导入目录不能获得能力。参数在官方 parser 完整解析、验证后由协议层分片；不是模型未完成的参数直接透传。

官方 SDK 验证入口及固定版本见 [DEVELOPMENT](DEVELOPMENT.md)，实际运行范围见 [VERIFICATION](VERIFICATION.md)。
