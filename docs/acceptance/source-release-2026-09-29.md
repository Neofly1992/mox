> 2026-09-30 独立复核发现 F1–F3 与 A1/A2 尚未闭合；本报告为历史收口证据。后续修改及最终验证见[治理报告](source-release-governance-2026-09-30.md)，不能据本文宣布当前版本放行。

# 首版源码发布收口验收报告

更新：2026-09-30。状态：**源码修复与自动验收完成，独立复核及用户人工验收待完成；未放行发布**。

## 范围与版本

- 要求来自 [2026-09-29 全仓审查](../reviews/repository-2026-09-29.md)。基线 `c6b7b5d`，分支 `codex/rewrite`，本轮修改未提交、未推送。
- 开始时已有 HANDOFF、`docs/reviews/M3-independent-2026-09-24.md` 的修改，以及未跟踪审查报告、探针和 `scripts/__pycache__/`；这些内容已保留。
- 最终 Release buildID：`mox-m4-a2a2c569cf0a2f690482af2e6f0e4b29a5d7a48b386bc8ad3a241c61a2bba812`。产物 `.build/m4/Release/Mox.app`、`.build/m4-worker/Release/mox`。
- Apple Silicon / macOS 27 / Xcode 27 / Swift 6.4。macOS 15 仍只是部署目标。范围不含签名、公证、Homebrew、Pi、多模态或新增公开协议。

## 修复与验收映射

| 审查项 | 根因处理 | 修改后证据与边界 |
| --- | --- | --- |
| R1 下载卡在 downloading | 下载与配置写入进入同一 mutation gate；等待后使用最新状态；保存失败不冒充活动任务 | Core 39 项含配置保存撞下载进度回归；运行库进度按任务 ID 写入 |
| R2 加载失败不能重试 | 共享加载任务按全部等待者生命周期清理；显式失败释放 task 和 reservation | Core 覆盖显式失败后重试、共享失败只调用一次 backend、取消与恢复 |
| R3 私有 HTTP body 无界 | 两 listener 共用大小、读取期限及拒绝响应关闭策略 | Service 54 项含未终止 chunked 413/关闭与后续请求；最终 SDK 真 socket 负向路径通过 |
| R4 退出漏算后一页下载 | ServiceState 单独提供全量活动下载计数，不依赖页面 | 跨页计数回归通过；App 退出可见提示待人工验收 |
| R5 模型页错误不可见 | 持久显示操作错误，并提供刷新恢复入口 | App 编译通过；导入/卸载/删除失败的可见行为待人工验收 |
| R6 模型标识不一致 | CLI 明确 alias/UUID 与本地目录两种入口；App 展示/复制实际 alias；测试页复用模型导入流程 | Service alias 回归、最终 Release 自定义 alias 导入及真生成通过；GUI 复制待验收 |
| R7 诊断分散 | 管理、下载终态、公共 listener 和 App 操作进入有界脱敏事件 | Service 故障与导出规则通过；GUI 导出待人工验收 |
| R8 默认参数与 pin 缺失 | 按原承诺实现逐字段显式请求 > 模型 > 启动 > 全局 > 产品默认及来源；持久模型固定；启动队列/安全预算调节；连接后保留参数读取失败 | Core 优先级、pin 淘汰回归和 Service 配置冲突/重开通过；CLI 真生成显示三种来源；GUI 来源与设置待验收 |
| R9 worker 陈旧 | 唯一脚本先解析依赖、再计算源码身份及构建 worker；Xcode embed 拒绝陈旧或缺失 staging | 最终工作区及无编译产物的干净检出 worker/App 均成功；两者 buildID 相同 |
| R10 开发期兼容层 | 默认用户对话库先备份、验证副本、转换原库；移除 V1/迁移计划、旧单 blob runtime 和缺字段猜默认值解码 | 正式 schema 重开、严格格式回归、原库 ID/数量核对通过；完整备份保留；未知自定义根需单独处理 |
| R11 文档冲突 | README、技术设计、里程碑和验收状态同步当前能力、默认值与构建入口 | README 构建步骤已在干净检出执行；人工状态未代填通过 |

## 最终自动验收证据

以下均为对应修改后的实际执行结果；早期 36/52 项、旧 buildID 和旧 GUI 结果不作为最终通过依据。

| 验证 | 结果 | 日志 |
| --- | --- | --- |
| 完整仓库 Xcode Core suite | **39 项通过**，含正式元数据缺必需状态时拒绝解码 | `.build/prepublish-strict-core.log` |
| 完整仓库 Xcode Service suite | **54 项通过**，最后的运行库错误说明和聊天错误保留改动后复跑 | `.build/prepublish-delivery-service.log` |
| 完整仓库 Xcode Sources suite | **7 项通过**；此 runner 的两项网络条件分支未启用 | `.build/prepublish-strict-sources.log` |
| `MOX_TEST_REAL_SOURCES=1 xcrun xctest` | **7 项通过**；真实 HF/ModelScope 各下载并核验一个固定版本 config.json | `.build/prepublish-strict-sources-real.log` |
| 唯一入口 Release 构建 | worker/App 两次 **BUILD SUCCEEDED**；identity check 通过 | `.build/prepublish-delivery-release.log` |
| 最终干净检出 Release 构建 | worker/App 两次 **BUILD SUCCEEDED**，buildID 与工作区一致 | `.build/prepublish-clean-delivery.log` |
| 官方 OpenAI/Anthropic SDK + 最终内嵌 worker + 真实 Qwen3 | 文本、流式、两协议工具往返、流式工具参数、错误工具结果续答、HTTP 鉴权/拒绝/连接关闭路径全部 **PASS** | `.build/prepublish-delivery-sdk.log` |
| 最终 CLI 参数继承真生成 | `max_tokens=12 [model] / temperature=0 [global] / top_p=0.7 [request]`，真实文本、正常 length 终态 | `.build/prepublish-delivery-chat.stderr`、`.stdout` |
| 最终 CLI 自定义 alias 真生成 | 导入 `release-review-alias`，按 alias 调用真实模型，正常 length 终态 | `.build/prepublish-strict-alias-import.log`（创建安装）；`.build/prepublish-delivery-alias.stderr`、`.stdout`（交付版生成） |
| 差异与构建身份 | `git diff --check` 通过；stamp check 与工作区/干净检出 CLI 版本相同 | 本报告最终 buildID |

Xcode 测试命令统一使用 `.build/m4-package.xcworkspace`、对应 `MoxCoreTests/MoxServiceTests/MoxSourcesTests` scheme、Debug、`platform=macOS,arch=arm64`、`.build/xcode` derived data、`-skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`。真实来源测试显式设置 `MOX_TEST_REAL_SOURCES=1`。SDK 可复跑入口为 `scripts/verify-m4-sdk.py`，先在隔离数据根启动本次构建的前台 worker 并开启 API，再传 App、data root 和受管 Qwen3 安装 UUID；脚本本身不启动服务、不打印密钥。

最终干净检出 `/private/tmp/mox-release-final-Xc88SV` 来自本地 Git 基线，覆入最终源码、Tests、App、脚本、锁文件和文档；没有复制编译产物，依赖 checkout 缓存来自本机。这验证源码构建，不代表无缓存网络环境或 GUI 体验已验收。日志已复制回工作区，临时目录可能被环境清理。

首次干净检出曾因依赖解析规范化锁文件而触发陈旧 worker 拒绝；根因修正为依赖解析在 stamp 之前，锁文件同步规范化，随后重跑通过。Xcode CoreDevice/Simulator 插件警告没有阻断上述实际测试和构建。

默认 SwiftPM 全仓测试路径曾因 Metal 工具发现失败；受限环境的 loopback/Keychain 测试曾停滞或返回状态 -50，未计为通过。最终改用完整仓库 Xcode 和正常本机执行环境验证。旧隔离根 Keychain 读取曾阻塞，SDK 最终使用新隔离根和新凭据通过；测试结束已停止本次启动的 worker。

## R10 数据保护记录

用户明确批准备份并一次性转换本机默认开发期对话库。首次自动审批因用量额度拒绝的备份命令未执行；审批恢复后完成以下步骤：

1. SQLite backup API 创建一致性完整备份 `~/Library/Application Support/Mox/conversations/Conversation.pre-source-release-2026-09-29.backup.sqlite`，90112 字节，`integrity_check=ok`，完整备份继续保留。
2. 隔离副本 V1 读取、迁移到 V2、独立重开；随后转换原库并独立重开。全程没有输出对话正文。
3. 移除生产迁移代码后用新源码重开副本和原库。会话/消息/生成记录数量均为 **1/0/0**；排序会话 ID 的 SHA-256 一致：`9f4c168ce64322c65d8030127a842dcd15c9c8b618c9f6bfba87e8a71d518ea7`。
4. 2026-09-30 只读 metadata 复核仍为版本 **2.0.0**、数量 **1/0/0**，备份存在。默认目录没有旧 runtime 库，因此未改用户模型记录。

首版只打开正式初始 schema，保留磁盘版本 2.0.0 和固定列名以读取已转换的数据；没有 V1 schema、开发期迁移计划或旧运行库分支。必要状态缺失会报 storageFailed，不能静默用空库或猜默认值代替。未知自定义数据根未被转换或删除；如用户使用过，须先识别、备份并单独确认一次性转换。测试根的旧元数据仅在隔离副本一次性规范化，转换代码未加入生产源码。

## 架构建议与剩余风险

| 建议 | 本轮决定与边界 |
| --- | --- |
| Core 用例职责 | 下载/加载状态由各自 actor 持有，能力证据移入 Core 策略；Server 仍有凭据更新与删除准入编排。没有进一步全量拆路由；此边界列为独立复核重点。 |
| Persistence 增长 | 高频进度按 operation ID 写入；配置/安装跨记录变更仍使用 snapshot diff。传输分页不能等同全链路有界查询，大库规模仍需后续测量。 |
| 共享策略 | 两 listener 共用 HTTP body/拒绝关闭策略；Domain 统一采样默认与来源；Coordinator 统一加载收尾与 pin 淘汰规则。 |
| UI 旧入口 | 模型选择/导入复用模型库流程；历史路径仅保留历史关联，不重建可选模型库。 |
| 可扩展边界 | 来源 enum/factory 和固定受管工具模型证据保留；未建设通用插件平台或重写 MLX。 |

启动全库权重 hash 与 readiness、长 model load/source resolve 与客户端 15 秒等待、工具 schema 支持约束、公共流聚合上限，仍是审查提出的未充分实测风险；没有编造失败或通过结果。真实私有镜像、物理断网、macOS 15 真机和任意第三方 agent 尚无完整环境证据。真实来源 config 获取不等于重新下载完整模型；SDK 使用既有受管 `mlx-community/Qwen3-0.6B-4bit@73e3e38d981303bc594367cd910ea6eb48349da8` 测试产物。

## 少量人工验收

GUI runner 因 Mac 锁屏和启用 automation mode 超时未成功执行，本轮没有 GUI 可见行为通过证据。准备：解锁 Mac，使用最终 App 和一个可用的小型 MLX 模型。可直接运行：

```sh
open .build/m4/Release/Mox.app
```

人工只需确认：

1. 打开最终 App，原会话仍可见；导入无效目录后模型页稳定显示错误，刷新可恢复操作。
2. 查看全局/单模型参数及每字段来源，固定模型并测试；复制实际模型标识用于 API，确认页面展示符合已测能力。
3. 活动下载时退出 App，确认提示；连接外部 worker 时退出 App，外部服务继续运行。跨页计数已由自动测试覆盖，无需人工创建大量历史任务。
4. 触发一次管理失败并导出诊断：有阶段、错误码和任务 ID，没有密钥、prompt 或完整私人路径。

失败时在 App 服务控件导出诊断，连同所处页面、操作及可见错误保存；测试下载可暂停/取消，测试本地引用可从模型库移除而不删除原目录。保留本次用户对话库备份。

独立会话应核对当前 Git 差异、R1–R11 映射和上述日志，并按 README 复跑构建。M2/M3/M4 人工状态保持待验收；未提交、推送或发布。
