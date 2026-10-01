# 首版治理独立复核（2026-10-01）

基线：`codex/rewrite`，HEAD `c6b7b5d` 加未提交治理工作树。生产身份 `mox-m4-d88127e067682abda153d34763a1ed66ef5c7fe13c4f88d80bea6ac43455fba5`。本轮未改生产代码或用户数据、未提交推送；保留全部先前修改。

## 结论

**上轮 F1–F3、A1/A2 的主要整改可关闭；首版仍待下述三个具体边界收口，尚未放行。** 不再要求一轮泛化架构治理，也不否定本次实质改进。G1/G2 已独立复现；G3 是有明确失败条件的源码/契约问题，未冒充大库真机实测。

## G1 · P2：文件已提交、索引保存失败后，正常重试反复失败

位置：`Sources/MoxCore/DownloadManager.swift:343–357,429–460`；`Sources/MoxCore/ArtifactStore.swift:79–105`。

原子 rename 成功后，installation + operation 的持久提交仍可能失败。catch 将任务记为 failed，但 resume 无条件重新进入暂存下载路径；原 staging 已被 rename 移走，因此重新获取所有文件，最后 RENAME_EXCL 遇到已经存在的目标目录返回 busy，任务再次 failed。底层存储恢复后，用户正常点击继续也不能完成安装。

独立故障注入只让首次含 installation 的 commit 失败，后续保存全部恢复。结果：首次产物目录确实存在；重试后任务仍 failed，文件获取调用从 4 增至 8。没有模拟网络故障或持续磁盘故障。探针见 [probes/2026-10-01](probes/2026-10-01/README.md)。已有启动恢复代码可处理未建索引的已提交产物，但未被正常重试使用；不是不可恢复的数据丢失，不能因此宣称重试已闭合。

修复：把已提交产物确认及索引补全作为统一、幂等的安装完成步骤，供启动恢复和显式重试共享。必须检查来源身份、manifest 与完整性，不能见目录存在就宣告成功；无需删除已完成产物或重新下载。覆盖 rename 后索引失败→同进程重试、重启恢复、冲突/损坏目标。

## G2 · P2：合法导入的 UUID 形状别名无法被使用

位置：`Sources/MoxCore/ModelLibraryService.swift:221–225`，对照 `DownloadManager.importDirectory`。

导入允许任意非空、非保留前缀且不冲突的 alias，但解析 installed 字符串时，只要能解析为 UUID 就只查 installation ID，不再查 alias。同一标识的写入/解析契约不一致；若该 alias 恰好等于另一条 installation ID，还可能解析成另一模型。

当前 Release、独立临时根实测：导入 alias `00000000-0000-0000-0000-000000000001` 返回 200；用该 alias 查询有效参数返回 404/notFound；用返回的实际安装 UUID 查询为 200。生成入口共用相同 resolve，GUI 显示/复制这个 alias 也不能修复解析。

修复：统一 ID 与 alias 命名空间及冲突规则，使用明确类型或无歧义解析。可保留 UUID 形式 alias 并处理冲突，或在创建入口明确保留该命名空间；不能允许创建成功再让读取猜错。覆盖 UUID 形状 alias、真实安装 UUID、alias 与另一 ID 冲突，确保 CLI/GUI/API 一致。调整用户可用 alias 规则应同步文档。

## G3 · P2：全库校验仍阻塞就绪，超过 15 秒就被启动者杀掉

位置：`Sources/MoxCLI/Serve.swift:59–71`、`Sources/MoxCore/DownloadManager.swift:515–532`、`Sources/MoxClient/Connection.swift:45–74`、`Sources/MoxProtocol/ServiceTiming.swift`。

Serve 在创建管理 listener 和发布 discovery 之前 await DownloadManager.open；recover 对每项受管安装调用完整 verifyContents，逐块读取并 hash 权重。与此同时，GUI/CLI 自启 worker 的 Connection.open 固定等待 15 秒，超时后 forceStop。因而恢复超过 15 秒时结果不是“启动慢一些”，而是合法 worker 被终止、无法连接；每次重试从头再校验。

报告将其描述为“大库冷启动时延未实测”，没有覆盖这一确定的生命周期冲突。技术设计 §4 已要求完整性校验与服务可用性分离。本轮未构造巨大真实模型库或宣称测得其耗时；这里的结论严格限定为：**一旦恢复超过期限，该故障分支必然发生，当前没有可表达的 recovering 就绪状态或进度契约。**

应把服务探活与模型完整性就绪分开，提供受控、可取消的恢复/校验状态；未校验模型不得推理，健康条目不应被无关全库工作阻挡。启动期父进程控制和关闭也应在耗时工作前成立。不要只将 15 秒改成另一个大常量。用可控慢恢复验证超过原期限仍可探活、不能误用未校验模型、退出可终止自己拥有的恢复工作；另做合理规模真机验证。

## 已关闭事项与架构判断

- F1：生命周期门闩与保存门闩分离；resume、cancel、shutdown 准入回归通过，旧探针已纳入正式测试。G1 是安装完成另一故障窗口，不是原并发恢复仍失败。
- F2：以 bodyConsumed 管理错误出口，删除旧预检遗漏；原三项 Release socket 探针本轮全部主动关闭，413/404 均有 Connection: close。
- F3：SamplingSettingsDraft 返回成功状态，失败保留字段，提交期间禁用/阻止重复请求；controller 抛回提交错误，编辑窗只在成功后关闭。草稿故障测试通过；本轮未代替用户检查完整可见体验。
- A1：ModelLibraryService 在 Core 拥有凭据事务、生成/加载/删除准入、pin 协调、来源获取和参数解析；ModelRuntime/ModelSourceFactory 是真实依赖边界，不安全元数据操作收为内部。Server 调用用例，新增直接 Core 测试。这是职责迁移，不是机械拆文件，可认可。
- A2：生产已移除 readLibrary/saveLibrary 全库缓存与 diff；RuntimeStore 按 ID commit，同事务更新索引/摘要，数据库谓词与分页；DownloadManager 不再常驻完整库。测试确认单项访问不解码无关损坏 payload。摘要投影作为同事务派生数据是合理设计，不构成第二业务权威。
- 新累计输出/工具边界进入 Core handle；诊断不可取得有显式状态；HF 选型描述同步；未恢复旧生产 schema 兼容分支。没有证据要求更换 SwiftData、MLX 或再次重写。

## 本轮证据与验证边界

| 独立执行 | 结果 |
| --- | --- |
| 当前源码 Xcode Core suite | 48 项通过，`.build/review-20261001/core.log` |
| 当前源码 Xcode Service suite | 61 项通过，`.build/review-20261001/service.log` |
| 当前交付 Release 三项未消费 body 真 socket | import 413 / downloads 413 / 未知模型 sampling 404 全部主动关闭，`http.json` |
| 当前交付 Release UUID alias | 导入 200、alias 查询 404、实际 ID 查询 200，`alias.json` |
| 原样 Core 隔离包安装索引失败探针 | 两断言失败：仍 failed、下载次数 4→8，`commit-probe.log` |
| 生产 stamp / git diff --check | 通过，身份与报告最终版本一致 |

规则测试命令使用 `.build/m4-package.xcworkspace` 对应 MoxCoreTests/MoxServiceTests scheme，Debug、arm64、`.build/xcode` derived data、CODE_SIGNING_ALLOWED=NO。探针在新临时根执行，服务由探针自行启动和停止，不访问默认用户数据。

已检查实现者机器证据 `.build/governance-e2e-final.json` 与最终身份匹配；完整双源下载、官方 SDK、Release GUI 两项和 Release 构建仍标为实现者证据，本轮没有无意义重复完整大下载、没有冒称自己重跑了 GUI/SDK/Release 构建。macOS 15、真实私有端点和人工体验状态仍由原报告如实保留。

下一步聚焦 G1–G3 定向修复及验证，然后进行最终人工验收；无须重开 A1/A2 泛化治理。源码发布不要求签名、公证、Homebrew。
