# Mox 首版源码发布前全仓评审

日期：2026-09-29。基线：`c6b7b5d`（`codex/rewrite`，本地与已获取的 `origin/codex/rewrite` 一致）。开始时已有的 M3 独立审查补记和 `scripts/__pycache__` 均保留。本轮没有改生产代码、提交、推送或发布。

## 结论与发布口径

**不建议现在将其宣布为已完成的第一版。可以继续公开开发，但应先完成一轮跨里程碑收口，再打源码版本标签。**

现有架构值得保留，不需要删库重写：原生 App、用户级 worker、官方 MLX、Domain/Core/适配器边界、真实取消、安装原子性与对话存储已有实质实现和证据。问题不是缺少另一套框架，而是已承诺能力在不同入口、状态转换、错误诊断和文档中没有完全统一。

这次发布仅指 GitHub 源码版本。Developer ID、签名公证、Homebrew、干净账户二进制安装不作为本次门槛；不能拿 P1 二进制发布要求阻止源码发布，也不能将源码已 push 等同于功能首版验收。

下面 R1–R7 是具体实现缺陷；R8–R11 是首版契约、工程原则与源码交付缺口。P1 表示优先处理的可靠性问题，P2 表示本次收口应处理的正常优先级问题。没有发现要求推翻整个系统的证据。

## 独立验证及边界

- 当前生产源码按仓库算法重算 buildID，与已交付 Release 相同：`mox-m4-286ce3dd39dd651231aa0a02ddd04279a0f85a494cbd90258bb17fb702f36684`。这验证源码身份声明一致，不将已有二进制冒充本轮全新构建。
- 原样复制当前 Domain/Core 与 CoreTests 到隔离 Swift package：原有 33 项测试通过；新增两个故障探针均失败，分别复现 R1/R2。随后去掉主动关闭下载的步骤复跑，仍复现 R1。探针保存在 [probes/2026-09-29](probes/2026-09-29/README.md)。日志 `.build/review-20260929/core.log`、`core-probes.log`。
- 当前源码 Xcode `MoxServiceTests`：49 项通过；`MoxSourcesTests`：7 项测试函数通过，但其中两项真实网络测试未设置 `MOX_TEST_REAL_SOURCES` 而直接 return，不能算真实双源验证。日志 `service.log`、`sources.log`。
- 交付 Release：在新临时数据根克隆已有受管 Qwen3 固定产物，启动自有 worker，完整运行仓库 `scripts/verify-m4-sdk.py`；两官方 SDK 文本/流、工具往返、错误工具结果、公共负向路径通过。上次 M4 独立审查 R1/R2 **本轮独立复核通过**。不重新下载模型；测试后停止自有 worker、清理临时根和该根专属公共 key。日志 `sdk.log`。
- 额外真 socket 探针：私有导入/API 设置接口返回 413 后仍不关闭连接，见 R3。额外 Release CLI 探针：导入自定义 alias 成功，但按 alias 聊天失败，见 R6。摘要 `release-summary.json`、`alias.json`。
- 本轮审查覆盖产品契约、技术方案、M1–M4/P1 规格与验收证据、生产各模块主要路径、构建/测试脚本和来源/MLX 的锁定 checkout 相关行为；没有把旧评审的结论直接当成现状。不是对全部线程调度、任意模型或任意硬件的穷尽证明。
- 构建与 GUI 实际结果见文末环境补记。本轮没有重跑完整真实 HF/MS 下载、私有镜像、macOS 15 或完整 GUI 长会话性能矩阵；历史证据与本轮结果分开。

## R1 · P1：配置保存会使下载任务停止却永远显示 downloading

位置：`Sources/MoxCore/DownloadManager.swift:51–57,282–320`。

`persist` 在任意保存进行时直接抛 busy。后台下载完成一个文件后也经过此入口；如果此时设置默认来源或切换公共 API 正在保存，进度 transition 抛 busy，`execute` 进入 catch，再次 transition 同样撞上保存，并被 `try?` 吞掉。runner 随 defer 消失，状态却仍是 downloading。显式 resume 又因状态不是 paused/failed/interrupted 而拒绝。

独立探针：阻塞一次配置 save，释放文件传输，保持保存锁 300ms 后放行；任务仍 downloading，resume 返回 busy。没有依赖网络、模型输出或关闭任务来复现。

修复：共享写入应串行化完整“读取最新状态→变更→持久化→发布”，后台进度和终态不能因为正常并发管理操作而丢失。不要只给 `try?` 增加日志，也不要在 await 前冻结过期快照后排队写回。增加配置/进度/取消/提交相撞的定向测试，确保任务的真实执行与持久终态一致。

## R2 · P2：显式加载失败后，后续加载一直复用失败 Task

位置：`Sources/MoxCore/RuntimeCoordinator.swift:186–215,225–248`。

`loadIntoSlot` 失败时保留 `loads[model.id]`。生成路径 run 的收尾会清理此项，但显式 load 的收尾没有对应规则。再次 load 在创建新 loader 前 await 已失败 Task，立即再次失败；模型状态也可能持续显示 loading。瞬时失败恢复必须重启或由其他路径间接清理。

独立注入 backend 仅第一次失败：第二次显式 load 仍失败，backend 实际 load 次数仍为 1。原有 `rollbackAndRetry` 只覆盖 generate，未覆盖显式加载。

修复：共享加载批次的生命周期、失败广播和释放统一归属 Coordinator，不让 load/generate 两条路径分别维护不同清理规则。测试显式 load→失败→再次 load，并确认状态和 reservation 正确。

## R3 · P2：公共 HTTP 修复没有覆盖私有管理接口

位置：`Sources/MoxServer/Service.swift:235–241,349–359,558–561,680–692`；对照 `PublicServer.swift`。

私有新接口聚合 body 超限时 throw，统一 catch 返回普通错误响应；既未将未读完 body 的 channel 关闭，也没有公共入口新增的 body 读取期限/idle 策略。共享 HTTP 资源规则因路由不同产生分歧。

实测已鉴权 chunked 请求，不发最终 0 块：`/mox/v1/models/import` 发送 16KiB+1、`/mox/v1/public-api` 发送 1KiB+1，均返回 413，之后 3 秒 socket 未关闭。与上次公共缺陷不同，这里需要私有管理凭据；不能写成未鉴权即可复现的漏洞。管理连接仍可被异常客户端占用。

修复：抽取 Server 内的有界读取/提前拒绝关闭/写出期限机制，两 listener 调用同一机制，协议层只决定错误体。覆盖所有 body 接口和未终止 chunked，而不是逐路由补丁。

## R4 · P2：超过一页任务后，退出 App 会漏掉活动下载

位置：`Sources/MoxChat/ChatController.swift:415–425`、`Sources/MoxDomain/ModelLibrary.swift:102–126`。

`prepareToQuit` 只取默认第一页 library 并用 `operations.contains(isActive)` 决定是否提示。M3 分页每页 25 项，历史 installed 任务保留、任务顺序按追加存储；第 26 项活动下载不会出现在第一页。无聊天任务时退出将不提示，而 App 随后关闭自己拥有的 worker，中断下载。这是 M3 分页改变 M2 退出语义的跨里程碑回归。

修复：由服务提供与列表分页无关的 active operation 摘要/计数；不要让 UI 为退出判断重新拼装全量历史。加“25 个历史任务+后一页活动下载”的退出规则测试，外部 owner 仍不得被 App 停止。此项为源码确定路径，本轮未运行相应 GUI 场景。

## R5 · P2：模型页的操作失败没有显示出来

位置：`App/LibraryController.swift:84–124`、`App/WorkspaceView.swift:202–205,260`。

导入、加载、卸载、删除、切版本等错误存到 `library.error`，模型页却只渲染 `chat.error`；`library.error` 只在下载页和获取弹窗显示。用户在模型详情收到 busy/无效目录/存储失败时，当前页面看不到原因。这直接违背“原型也必须可诊断”的原则。

修复：在实际发起操作的页面显示稳定错误及恢复动作，共享错误呈现/诊断入口。验证错误本地导入、活动推理时卸载/删除失败、持久保存失败；不能只断言 HTTP 错误码正确。

## R6 · P2：模型标识在 CLI、GUI 和公共 API 间不一致

位置：`Sources/MoxProtocol/Wire.swift:109–113`、`Sources/MoxCLI/Mox.swift:39–43`、`App/WorkspaceView.swift:90–102,142`、`App/PublicAPIView.swift:99`。

- CLI 声称支持 installed alias，但 `GenerateBody` 仅将以 `mox:` 开头的字符串识别为 alias；用户导入时设置的 `review-import` 被解释成文件路径。本轮 Release 实测 import 返回 0、`chat --model-path review-import` 返回 1：`invalidModel: Model directory does not exist.` 公共 API 却按库中 alias 接受这类名称。
- API 页指示用户填写“模型页显示的已安装别名”，而托管模型列表显示 repository、详情显示 revision/path，均没有完整 alias/installation ID。托管 alias 实际含 registry UUID，用户无法从页面所见直接推导。

修复：明确目录与安装标识的类型/CLI 输入方式，用共享模型解析用例处理 alias/ID；GUI 展示并可复制真实 API model 标识。覆盖本地引用与托管安装，不靠字符串前缀猜所有用户意图。

## R7 · P2：下载与公共 API 的诊断没有进入统一导出

位置：`Sources/MoxChat/ChatController.swift:492–527`、`App/LibraryController.swift`、`App/PublicAPIView.swift`、`Sources/MoxCore/DownloadManager.swift:316–320`。

全局“导出诊断”只导出 ChatController 的 ring、聊天状态和进程输出字节数。Library/API 各自只保存显示字符串，不记录共享事件；下载 catch 还把非 MoxError 压成 sourceFailed，保存终态失败直接忽略。用户下载/配置/公共 API 操作失败后导出，可能只有聊天连接正常、没有出错 operation/阶段/底层安全错误分类。报告中的“inspect diagnostics”缺乏对应可取得的证据。

修复：建立跨功能、脱敏且有界的诊断入口，保留来源操作/持久保存/public listener 的稳定 stage/code、关联 ID 和允许公开的系统 error domain/code。View 负责展示，不直接收集原始异常文本。失败注入后检查导出能定位对应操作，同时不含 token、签名 URL、prompt 或完整路径。

## R8 · P2：首版配置契约未实现，验收状态未明确缩小范围

依据：M3 规格“管理、删除与 lease”及 M3-R06；技术设计 §6/§9。位置：`Sources/MoxDomain/ModelLibrary.swift:156–174`、`Sources/MoxDomain/Generation.swift:64–78`、`Sources/MoxServer/PublicProtocol.swift`、`Sources/MoxCLI/Mox.swift`、`Sources/MoxChat/ChatController.swift:50–51`。

规格承诺显式请求 > 模型设置 > 有效全局 > 产品默认，以及启动覆盖/provenance。实现的配置仅 registry/defaultRegistry/publicAPIEnabled；没有模型生成设置或 EffectiveConfig，各入口分别填 2048/0.6/1。`MOX_DATA_ROOT` 仅 App 消费，CLI 有独立 flag；这不能替代模型参数的覆盖验收。M3 报告仍 PARTIAL，而 M4-R06 写整体 PASS，没有清楚闭合这一缺口。

此外技术设计仍承诺 pin 与可配置队列/预算，源码没有 pin 状态或设置接口。M1 明确当时不做 pin 合理，但 M4 收尾时应明确哪些仍属于后续，而不能同时保留“初版必须”和“全部通过”。

修复：先收敛一张首版契约表。建议落实轻量的默认参数解析与 provenance，入口只传显式覆盖；不建设泛化配置平台。pin/独立模型目录迁移等若暂缓，必须作为明确范围调整同步产品、技术、里程碑和验收，不能通过删除测试或改写 PASS 掩盖。

## R9 · P2：直接 Xcode 构建会嵌入旧 worker，源码交付缺少唯一构建入口

位置：`scripts/embed-worker.sh:3–15`、`scripts/stamp-m3-build.py`、`scripts/generate-xcode-project.py`。

Xcode App target 的 embed phase 只检查 `.build/m4-worker/$CONFIGURATION` 是否存在，再复制；不构建 worker、不校验该 worker 对应当前源码。buildID 只在外部 milestone 脚本里重算。贡献者执行过一次脚本后修改 Core/Server，再直接 Xcode Run，可以运行“新 App + 旧 worker”，且未重算 buildID 使身份握手也未必发现。首次 clone 直接打开工程则因 staging 不存在失败。

修复：提供唯一、可重复的开发构建路径，让 worker 编译、资源、身份和嵌入成为实际依赖；若保留外部脚本，Xcode 至少检测输入变化并明确阻止陈旧嵌入。收敛 milestone 命名的多套当前构建入口。测试修改 worker 源码后直接构建、Debug/Release 切换、缺失 staging；无需签名公证。

## R10 · P2：未发布的兼容层确实还在生产路径里

位置：`Sources/MoxPersistence/RuntimeStore.swift:6–14,55–69`、`Sources/MoxPersistence/ChatSchemaV1.swift`、`ChatSchema.swift:63,116–150`、`Sources/MoxDomain/ModelLibrary.swift` 的缺字段降级解码。

旧单 blob RuntimeStore 被显式打开并搬到 runtime-v2.store；聊天 V1/V2 保留历史 HTTP request 编码迁移。这是实际兼容成本，不是只建立 VersionedSchema。M2/技术文档后来将其写入规格，但与用户持续要求的“未发布不保留历史包袱”冲突；不能靠阶段文档自行豁免全局原则。

建议当前发布前整理为一个正式初始 schema，删除仅为开发中旧版本服务的代码/测试/双文件路径；继续保留 schema 版本管理能力，供真正发布后的数据演进。**清理兼容代码不授权删除用户现有对话或模型文件**；若确有需要保留的个人测试数据，应显式导出或一次性转换，不能将这一需求扩散成永久多版本支持。

## R11 · P2：README 与权威设计仍描述相互冲突的产品

位置：`README.md:5–38`、`docs/architecture/TECHNICAL-DESIGN.md:81–94,114–118,244–250`、`docs/milestones/M2.md:3`、`docs/milestones/M3.md:3`、`docs/DEPENDENCIES.md`。

- README 仍说 M1 待人工验收、GUI/HTTP/下载尚未实现，只提供 M1 CLI 构建和本地目录聊天；第一版源码用户没有当前 App/API 快速开始、能力子集或有效模型说明。
- 技术设计 §3.2 说公开固定 11555 且 serve 默认开启；§8 与 M4 则说默认关闭，实际为动态端口。属于同一权威文档内部冲突。
- §4 说 HF 官方 snapshot 下载；实际使用官方 metadata + 原生逐文件下载；后者可以合理，但旧承诺需要更新。
- M2/M3 状态标题仍写旧问题待复核/待修复，与 HANDOFF 和后续证据不同。DEPENDENCIES 标题/当前状态仍停留 M1/M2、M3 实施中。

修复：当前用户文档只讲当前可用行为；历史里程碑保存证据但不作为另一套产品定义。README 给出真实依赖、构建、启动、获取模型、GUI/API 示例、工具模型限制、数据与诊断位置、已知限制和可重跑测试。技术规范移除已被替代的当前契约，修订状态不能代填人工验收。API 子集必须让用户在调用前看见，而不是等 400 才知道。

## 产品与里程碑一致性矩阵

| 能力 | 当前判断 | 首版处理 |
| --- | --- | --- |
| 本地 MLX 加载/流式/取消/多轮 | 主要链路有实现和真实证据；显式 load 恢复遗漏 | 修 R2，保留现有官方 MLX 适配 |
| App/CLI/外部服务所有权 | 锁、发现、父子管道、外部 owner 保护方向正确 | 修跨页退出判断；核对长操作超时 |
| HF/MS/同协议来源/镜像 | 有 provider 边界、固定 revision、凭据隔离、真实历史证据 | 修 R1；真实私有镜像明确未验证 |
| 安装原子性/删除/引用保护 | 有摘要校验、rename、恢复、lease 准入，不能删掉这些“复杂度” | 保留，补并发失败回归 |
| 模型→聊天→API | 单条主路径可用，多个入口还没形成一致的标识/错误体验 | 修 R5/R6；ChatView 的目录选择也应复用模型入口 |
| 对话持久化/分支/取消 | 显式保存、受控恢复、分页与存储失败处理优于占位实现 | 简化旧 schema，不改用户文件所有权 |
| OpenAI/Anthropic 文本和工具子集 | 本轮两 SDK 与真实工具往返通过；上次两个问题已关闭 | 明确仅固定受管 Qwen3 工具能力；不声称全部 agent 兼容 |
| 配置优先级/模型默认参数 | 未形成规格所述产品能力 | R8：实现或明确调整首版范围 |
| 诊断与健壮性 | 聊天/运行时较完整，下载/配置/public 控制明显不齐 | R3/R7，不让用户承担基础排障 |
| 多模态/Pi/容器/Responses | 本轮明确不含；内容块有扩展边界 | 不是当前缺陷，不预建通用 agent 框架 |
| 源码公开与二进制分发 | MIT、依赖锁和测试已存在；首页/构建/范围未收口 | R9/R11；签名、公证、brew 后置 |

## 架构和编码原则评价

可以保留的部分：Apple 原生 UI/存储/网络；Domain 不依赖 HTTP/SwiftData；Core 不依赖 MLX；MLX 对官方算法的薄适配；独立 worker；资源预算/GPU 门闩/lease；有界队列；SwiftData 显式 save；受管快照与本地引用分离。没有理由为了“更新”再换一轮框架，也不需要竞品级 batching/custom kernel。

需要按职责整理，而非仅让测试变绿：

1. **Core 用例边界。** `InferenceService.response` 是大型路由分支，同时负责凭据更新事务、来源解析、模型删除准入和工具能力表。HTTP 并非这些业务的天然所有者。把完整模型/配置用例放到有明确职责的 Core 组件，Server 保留 DTO、鉴权、连接生命周期；不机械拆成几十个仅转发的方法。
2. **Persistence 使用方式。** RuntimeStore 虽分独立记录，但每次 saveLibrary 仍 fetch 全部 installation/operation 并 diff 整库，各 payload 是 JSON blob，分页只发生在传输层。不能称“全链路有界查询已完成”。对于增长的安装/任务库，应按 operation/installation 身份更新和查询，跨记录事务仍统一提交；SwiftData 本身无须更换。
3. **共享策略应真正共享。** HTTP 错误关闭、请求限制、加载收尾已出现漏改后果；采样默认值、状态字符串、循环轮询间隔亦散落各层。提取拥有明确语义的策略/状态，不建立万能 Utils 或替换所有显然字面量。
4. **UI 不保留第二条旧路径。** `ChatView.chooseModel` 直接修改路径，绕过 M3 的导入与选择流程；“最近目录”又从对话重建，可能把已移除的模型继续显示为可选路径。应保留历史关联，但把模型目录/选择和历史引用区分清楚。
5. **可扩展性不等于无界抽象。** 两种 provider 用 enum/factory 合理；工具模型能力白名单在 0.1 是诚实限制，可移到能力策略，但无需通用插件注册平台。明确支持子集优于虚假全兼容。

其他需要跟踪的边界（本轮未全部实测，不列为已证缺陷）：每次启动全库重算权重 hash 与 15 秒 readiness 的关系；model load/source resolve 与私有客户端统一 15 秒等待之间的关系；工具参数的“schema 基本校验”在现有 JSON parser 及 emitCall 中只看到对象/工具名检查，需明确支持的约束并补负向 fixture；公共流输出聚合/工具事件帧生成的上限应直接可见。没有为这些风险编造故障结果。

## 建议收口顺序与放行条件

1. 先修 R1–R7，新增针对因果的回归，不重复堆快乐路径测试。公共已修问题保留覆盖，并把共同规则落实到所有入口。
2. 收敛 R8–R11：一份当前范围、一个模型标识规则、一份默认参数权威、一个正式初始 schema、一条可信构建路径。凡实质减少原承诺的决定单独说明，用户无需逐方法审阅 spec。
3. 在干净 checkout 按 README 完成 build/test/App→获取→聊天→API；记录准确 commit、已跳过/受环境阻塞项。建议建立 GitHub CI 至少运行非模型规则/协议/存储测试，真实 MLX 另设受控机器入口。**没有 CI 本身不是本轮独立硬阻塞，但不能继续只有开发机日志。**
4. 用户验收少量可见路径，尤其错误反馈、退出下载、模型标识与 API 示例。M2/M3/M4 未有明确人工通过不能被本审查代填。
5. 以源码版本的实际支持声明发布；macOS 15 目前只能写部署目标/尚未实测，不写已验证支持。无需等待 Pi、多模态、任意 agent 或二进制分发。

修复以明确缺陷和边界为中心，不推荐再次全量重写。该仓库需要的是跨里程碑的一致性整理与失败路径闭合。

## 环境与构建补记

本轮环境：Apple Silicon，macOS 27.0（26A428），Xcode 27.0（27A266a）。

- 当前源码经 Xcode workspace 的 `mox` scheme、Release、arm64 构建成功；重建 worker 的 `--version` 与上述 buildID 一致。日志 `.build/review-20260929/worker-build.log`。因此存在本轮源码构建证据；SDK 集成验证使用前述身份相同的已交付 Release，不混为同一次产物测试。
- 默认 SwiftPM 测试构建报告 `cannot execute tool 'metal' due to missing Metal Toolchain`；后续 Xcode 构建成功，所以这里只认定该 SwiftPM 构建路径的工具链发现受阻，不声称整台机器缺少 Metal 或源码无法编译。
- Release App 与 UI runner 编译完成，但 runner 初始化报 `Timed out while enabling automation mode`，所选 `testM4APIControls`、`testM3ConfiguredMirrorSurvivesAcquireSheet` 未成功执行。本轮 GUI 结果为 **BLOCKED（环境）**，不是通过或已证产品缺陷。日志 `.build/review-20260929/ui.log`，结果 `.build/m4-app/Logs/Test/Test-Mox-2026.09.29_00-30-31-+0800.xcresult`。
- Xcode 规则测试使用 `.build/m4-package.xcworkspace` 的 `MoxServiceTests` / `MoxSourcesTests` scheme，Debug、arm64、`CODE_SIGNING_ALLOWED=NO`；worker 使用同 workspace 的 `mox` scheme、Release。该 workspace/构建缓存是本机既有生成产物，本次成功不替代 R9 所要求的干净 checkout 验证。

辅助日志可能随 `.build` 清理；本报告保留结果与限制，源码故障探针保留在审查目录。修复后需重新采集证据，不能沿用本轮结果宣布新代码通过。
