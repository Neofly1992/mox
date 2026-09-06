# 技术选型与竞品补充审查

日期：2026-09-05。本文补充 TECHNICAL-DESIGN，不是对约百万行竞品代码的完整质量认证。检查范围为依赖、架构、代码分布，以及下载、模型生命周期、GUI 进程监督、流式通信、持久化和相关测试的重点路径；未运行竞品性能测试。

## 1. ModelScope：有 SDK，但语言边界确实存在

官方已有 Python SDK，目前还提供独立轻量的 [modelscope-hub](https://github.com/modelscope/modelscope_hub)，要求 Python 3.10+，基础依赖为 requests/tqdm/filelock/urllib3。旧 modelscope 的 snapshot_download 已转发到新的 Hub 实现。不能说“没有 SDK”，也不能说“调用下载 SDK 必须带整套模型推理框架”。本次没有找到官方维护的 Swift Hub SDK；ms-swift 是训练框架，名称里的 Swift 不是 Apple Swift SDK。

本地 oMLX 的 `omlx/admin/ms_downloader.py` 调用 Python snapshot_download/HubApi，同时仍维护进度采集、超时、端点和缓存逻辑。这说明 SDK 减少协议维护，但不自动解决整个产品的下载生命周期。

建议保留原生 URLSession adapter：只实现仓库解析、精确 revision、文件清单/元数据、认证和下载定位；复用统一 ArtifactStore/下载事务，不复制另一套安装管理。必须有错误与分页 fixtures、真实公共仓库测试、受控断网/Range/远端变更测试。没有远端校验信息时如实记录可信度，不编造 checksum 或 immutable revision。SDK 优先是原则，跨语言 SDK 的运行时、签名分发和维护成本也要计入。尚未做 ModelScope 真仓库下载验收，G4 不可跳过。

## 2. Hummingbird：有生态依据，不宣称市场第一

[Swift.org 服务端文档](https://www.swift.org/documentation/server/) 将 Vapor 与 Hummingbird 一起推荐，[包目录](https://www.swift.org/packages/server.html)也收录 Hummingbird。其 v2 使用 Swift concurrency，建立在 NIO 上，并与 Swift HTTP Types、Service Lifecycle 生态结合。[官方论坛介绍](https://forums.swift.org/t/introducing-hummingbird-category/83576)

因此它是有维护与社区基础的合理选项，不能据此推导下载量第一或唯一最佳实践。Vapor 也是合理候选；对本项目这种小型本地推理服务，Hummingbird 的模块化路由/中间件更贴合需求，无需完整 Web 应用栈。更新的 [swift-http-server](https://github.com/swift-server/swift-http-server)当前 README 仍标 WIP，不因“更新”直接替代成熟框架。

具体版本在 G2 锁定稳定发布；验证 SSE flush、请求体上限、慢消费者、断连取消、优雅退出、同连接后续请求。不能用“框架支持 async”代替实际流式正确性验证。

## 3. XPC：价值是身份和 OS 生命周期，不是统一业务入口

Core 才是共同业务入口。App/CLI 经 HTTP 或 XPC 都应调用同一应用服务，不能在两个 handler 中复制业务。

| 维度 | 本地 HTTP | XPC 管理面 + HTTP 对外 |
| --- | --- | --- |
| 同用户进程身份 | 文件权限和 token，不能抵御同用户恶意进程 | 可约束 peer code signing；签名和开发构建策略需设计 |
| App helper | App 启动/观察子进程，处理退出 | bundled XPC service 可由 OS 按需启动 |
| 前台/brew/App 共用实例 | 同一锁、发现文件、client | 需统一 Mach service 注册或 endpoint rendezvous |
| 外部 agent | 使用 HTTP | 仍需 HTTP |
| 可观察性 | curl/协议 fixtures 直接复现 | 需 XPC client 测试工具；并非不可调试 |
| root | 不需要 | 不需要 |

推荐仍是 HTTP：当前优先级是零额外安装的 App、独立前台服务及 brew 托管共存；没有指定签名客户端专属访问要求。XPC 并不错误，也不是因代码难写而排除；它的额外生命周期体系在当前契约下没有足够收益。若加入强 peer 身份要求，收益即变得值得，应选 XPC 并明确用户级注册模型。Homebrew 支持自定义 service file，不能将它当成 XPC 不可行的理由。匿名 endpoint 同样需要交付路径，不是自动发现方案。

依据：[Apple XPC](https://developer.apple.com/documentation/xpc)、[NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)、[签名要求](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))、[Homebrew cookbook](https://docs.brew.sh/Formula-Cookbook)。这是一项架构判断，尚未进行双 transport 原型比较。

## 4. 代码量说明

统计各仓库 git ls-files 中的源码/脚本/网页扩展名（py/swift/c/cc/cpp/h/hpp/metal/m/mm/js/ts/tsx/jsx/html/css/sh），读取当时工作树，含空行和注释；按测试目录/文件名归类。排除文档、数据、未跟踪构建目录，不是逻辑 SLOC。HEAD 仅作为读取位置标识，工作树并非保证干净。测试行数不等于测试覆盖率。

| 仓库 | HEAD | 所选文件物理行数 | 非测试 | 测试 |
| --- | --- | ---: | ---: | ---: |
| oMLX | e467261e | 557,464 | 329,679 | 227,785 |
| MTPLX | e652d55 | 492,737 | 336,684 | 156,053 |
| Mox | c289c60 | 14,146 | 10,435 | 3,711 |

两个竞品的差距确实大，不能都用缓存/调度解释。oMLX App 非测试约 34,635 行，MTPLX App 非测试约 72,865 行；Mox GUI 约 859 行、GUIClient 约 503 行，仍是早期实现。另一方面 oMLX patches 64,470、custom_kernels 29,959、cluster 26,897、cache 18,376；MTPLX kernels 22,655、generation.py 12,885、benchmarks 11,091。很多是当前不必自己维护的推理优化与广泛功能。这些目录数字用于定位，不能相加推导可删行数。

## 5. 应借鉴什么，明确省略什么

| 能力/证据位置 | Mox 决策 | 验收 |
| --- | --- | --- |
| oMLX engine_pool.py：加载/使用标记、卸载后内存回收屏障 | 必需的正确性；用 RuntimeCoordinator、reservation、lease 实现。actor 不能代替这些规则 | G3 加载失败回滚、取消后立即再生成、禁止卸载在用模型 |
| MTPLX DaemonSupervisor.swift、对应测试：launch identity、epoch、过期回调、有限恢复 | 必须借鉴；自己的 worker 才可回收；外部服务不接管 | G2 假健康端口、启动竞争、停止中迟到 ready、崩溃与手动重启交错 |
| oMLX ms_downloader.py；MTPLX Onboarding 的 probe/downloader/feasibility | 下载不是单次 URL 请求；空间/型号/支持情况、鉴权与恢复都必须有 | G4/G5 磁盘不足、凭据错误、仓库不存在、模型不支持、恢复状态 |
| MTPLX ChatStore.swift：独立 SwiftData store、可注入测试位置、内存测试 store | 与已选 SwiftData 方向一致；领域模型不暴露 @Model | G1/G5 真持久化重开、部分回复和附件生命周期 |
| MTPLX MTPLXChatClient.swift、StreamingDocumentStore、UIStreamPerfProbe | 借鉴完整流式体验、取消区分和 UI 性能观测 | G5 分片 Unicode、SSE 边界、长输出、滚动、停止、失败后重试 |
| MTPLX BoundedLogStore.swift | 有界日志与结构化诊断必需；还需按字节上限和脱敏，不能只数条目 | G2/G5 stderr 持续排空、不阻塞进程、导出 request/instance 对应证据 |
| 两者 API 与 tool calling 测试 | 必须补；按协议语义验收，不能只测 JSON 字段存在 | G6 工具往返、stop/usage、错误、客户端实际连接 |
| MTPLX PiIntegration.swift | 学其独立集成服务及配置修改所有权；Pi 延后，用真实需求做薄 adapter | 后续扩展；不照抄终端体验或 agent 提示词 |
| 两者自定义 kernel、投机解码、分布式和大规模 batching | v1 不做；首先复用官方 MLX 能力 | 将来性能证据证明必要才引入 |
| 前缀/KV 缓存、长上下文 prefill 优化 | 不能永远归为定位外；agent 重复上下文直接影响体验 | 先测首 token、后续轮次延迟和内存，再决定官方能力接入 |
| 多模态 | 已确定后续必做，不能列为永久省略项 | 现在内容块/附件/能力设计；后续逐模型验收 |

路径以 `/Users/neo/Code/libre/MTPLX/apps/MTPLXApp/Sources/MTPLXAppCore/` 和 `/Users/neo/Code/libre/omlx/omlx/` 为根。两者使用成熟 Python HTTP 框架（FastAPI/Uvicorn），Swift App 与后端进程分离；值得学的是职责与故障处理，不必因此引入 Python。竞品也有很大的路由文件和特化实现，不应复制其模块体积或假定全部实现正确。

## 6. 必须纳入首版计划的补项

1. 新用户闭环：搜索/粘贴模型地址、变体与支持能力说明、粗略内存及磁盘预检、下载/加载/运行分阶段进度。不把估计内存标为保证能运行。
2. 管理闭环：取消/恢复、明确删除和引用的差异、可解释磁盘占用、凭据与镜像故障可定位；无支持能力时在昂贵下载前尽量提示。
3. GUI 健壮性：服务故障和模型错误分别呈现；迟到事件不覆盖新会话；长回复渲染节流、日志字节上限、诊断导出；保留失败和取消的真实状态。
4. 运行基线：真实小模型的冷启动、首 token、持续生成、取消耗时、内存峰值、连续多轮稳定性。暂不设凭空性能承诺；先记录可重复基线，再定预算。
5. 发布验证：干净账户独立 App；无 brew/Python；Metal 资源、签名/公证、CLI/GUI 并存；依赖清单和来源记录。参考实现时检查对应文件的许可与归属信息。

结论：Mox 代码少一部分来自合理定位和上游复用，另一部分来自真实未完成和正确性缺口。不能证明现有一万行已经足够；也不需要向几十万行靠齐。应按上述能力矩阵与 G0–G7 重建，保留经验证的实现思想和行为测试，不以旧代码体量或 AI 改代码的难易作为架构依据。
