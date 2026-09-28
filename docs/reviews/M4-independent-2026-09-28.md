# M4 独立审查（2026-09-28）

结论：主体实现及交付证据已建立，但本轮发现两项需要修复的正确性问题；M4 尚不能收尾。无需推翻架构。此审查不等于用户人工验收。

## 范围与实际验证

审查当前 `codex/rewrite` 未提交实现，重点检查公共 HTTP 边界、协议解析/编码、工具历史与生成、服务生命周期，以及规格和证据的一致性。保留工作区原有修改，本轮未改生产代码。

- 实跑 `swift test --scratch-path .build/m4-tests-final --filter MoxServiceTests`：47 项通过，退出码 0。日志 `.build/m4-independent-service-20260928.log`。
- 使用交付 Release worker `.build/m4-worker/Release/mox`（交付报告 buildID `mox-m4-7d0d7486491f0a59d298197963f99eed4a7c71aad7ead5e5284819ff2a07e623`），在临时数据根启动自己的 worker、引用已有 Qwen2.5 小模型、开启 API；密钥仅在探针内存使用。测试后关闭 API、终止自有 worker 并清理临时根，不改模型。
- 真 socket 分别验证未结束的请求体下 Origin 拒绝、无鉴权拒绝、声明超长拒绝；另以真实推理验证非法工具历史。结果摘要 `.build/m4-independent-http-probe.json`，核心复现见下文，临时日志可能被清理。
- 未重跑完整官方 SDK 工具往返、GUI 或全量 MLX 测试；原交付报告的证据仍属于实现会话，本轮不重复标作独立验证。

## R1 · P1：提前拒绝未读完请求体后，连接仍被占用

位置：`Sources/MoxServer/PublicServer.swift:26–37,59–67,148–166`。

Origin、鉴权和超长 body 拒绝返回普通 JSON Response，没有结束连接；公共 listener 配置最多 64 个连接，却未配置读取/空闲期限。当前 Hummingbird 的 HTTP1Channel idleTimeout 默认 nil。客户端不结束请求体时，错误状态已经返回，但连接没有随拒绝释放。未鉴权客户端也能占用连接配额，影响正常 API 请求；这是资源生命周期问题，不只是错误码是否正确。

实测：向新启用的公共 endpoint 发送 `POST /v1/chat/completions`：

1. `Origin: https://example.invalid`、`Transfer-Encoding: chunked`，不发送终止块：返回 403，之后 3 秒未关闭连接。
2. 无鉴权、chunked 且不发送终止块：返回 401，之后 3 秒未关闭连接。
3. 正确 Bearer 与 JSON Content-Type，`Content-Length: 16777217`，不发送 body：返回 413，之后 3 秒未关闭连接。

本轮没有实际占满全部 64 个连接；连接配额耗尽风险由上述实测及无读取期限的配置共同支持，不将其写成已实测的全量拒绝服务。

修复要求：未读完 body 的提前拒绝路径应在有界错误写出后关闭连接，不能无限排空客户端剩余 body；统一处理其他同类提前返回路径。参考已有私有入口的关闭语义，合理复用，不再维护另一份不完整策略。补真 socket 回归，覆盖未终止 chunked、声明超长和聚合中超限，验证响应、连接释放及后续正常请求仍可用。

## R2 · P2：工具调用匹配没有校验对话轮次

位置：`Sources/MoxDomain/Generation.swift:96–117`；对照 M4 规格 OpenAI 请求契约。

校验仅用贯穿整个历史的 pending ID 集合，最终检查集合为空；没有在新 user/assistant 轮次开始时检查上一轮工具结果是否已经完整。因此工具结果可以跨过无关消息，仍被当成合法历史送入模板与推理。规格已要求结果匹配前一 assistant 的工具调用，不应由模型猜测错误历史。

实测：正确鉴权后提交以下消息，`model` 为已导入 fixture，`max_tokens: 1`；实际返回 HTTP 200 并进入推理，而应在推理前返回 400。

```json
[
  {"role":"user","content":"hi"},
  {"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"lookup","arguments":"{}"}}]},
  {"role":"user","content":"unrelated intervening turn"},
  {"role":"tool","tool_call_id":"c1","content":"ok"}
]
```

修复要求：以明确的轮次状态校验待返回工具调用，允许同一轮多个结果，拒绝未完成结果时跨入无关对话轮次。共享业务约束由领域层单处负责，协议特有块/角色规则由适配层处理；保留合法 Anthropic 混合内容的顺序。增加两协议非法跨轮历史、部分返回后跨轮、合法多结果历史测试；至少补一条真实 HTTP 拒绝证据，确认未启动推理。

## 下一步

先修 R1/R2 并补对应回归，定向独立复核后再进行用户体验验收。既有 SDK/GUI 成功证据不因此作废，但不能覆盖上述负向路径。修复后更新交付报告及 HANDOFF，不把 AI 自测或此审查等同于用户验收。
