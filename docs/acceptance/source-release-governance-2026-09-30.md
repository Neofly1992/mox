> 2026-10-01 独立复核认可 F1–F3/A1/A2 主要整改，但发现 G1–G3，首版未放行。后续修复与新产物证据见[定向报告](source-release-g123-2026-10-01.md)；本文为上轮历史证据。

# 首版源码发布治理验收（2026-09-30）

状态：F1–F3、A1/A2 与原 R1–R11 收口实现及本机最终自测完成，待独立复核与人工验收；外部环境阻塞另列，不代填人工验收。基线为 `codex/rewrite`、`c6b7b5d` 加已有未提交收口修改；原两份审查保持原样。最终生产身份与本轮端到端证据见下文。

## 治理与验收映射

| 项目 | 根因与实现 | 回归与验收 |
| --- | --- | --- |
| F1 / R1 | DownloadManager 生命周期门闩覆盖 create/resume/pause/cancel/discard/shutdown；与持久变更门闩分离，停止等待 runner 不阻塞终态保存；shutdown 先封闭准入 | 并发 resume、准入中 cancel/shutdown、配置保存撞进度、取消/恢复/提交故障；最终 worker 获取链路 |
| F2 / R3 | Server 跟踪 body 完整消费，所有异常出口统一主动关闭未读 body；删除重复长度预检；两 listener 共用读取与错误状态策略 | 未终止 chunked、超限声明长度、不存在模型/路由、不可用服务、认证失败、慢读真 socket；最终 Release 探针 |
| F3 / R5 / R8 | SamplingSettingsDraft 保存返回成功状态；失败保留字段、可重试、排除重叠提交；controller 保存失败抛错，提交成功后的刷新失败另报 | 草稿存储失败/重试/重复提交；GUI 可见体验仍需人工 |
| A1 | ModelLibraryService 通过 ModelRuntime、ModelSourceFactory 与 DownloadManager 注入依赖，拥有来源凭据事务、获取计划/启动/恢复、参数解析、生成/加载/删除准入、pin 协调；不安全的元数据删除/pin/来源更新仅 Core 内部可见 | 直接 Core 调用的凭据/pin 回滚、加载中及 runtime busy 删除保护；单项参数解析与 HTTP/公共生成回归 |
| A2 | ModelLibraryPersistence 按配置、安装/任务身份提交 LibraryChanges；SwiftData 谓词/索引、摘要投影和 fetchOffset/fetchLimit；删除仅查询对应版本家族；无生产 readLibrary/saveLibrary 或全库缓存/diff | 存储分页/重开、单项访问不读 catalog、无关损坏 payload 不阻断其他单项修改或摘要查询、大清单响应回归 |
| R2 | RuntimeCoordinator 共享加载失败收尾与 reservation 回收保留 | 显式失败重试、共享失败/取消、再生成 |
| R4 | 退出准入使用数据库活动任务计数，与页面无关；读取失败显式失败，不伪装 0 | 25 项历史后的活动任务；GUI 提示待人工 |
| R6 | 安装 alias/UUID 与目录输入分开；GUI 展示可复制标识、统一导入路径 | 服务冻结 alias、最终 CLI alias/UUID 与 SDK；GUI 待人工 |
| R7 | 来源凭据退休清理失败进入 Core 有界诊断；任务诊断查询最近有界摘要并补活动任务；获取服务诊断失败导出 unavailable，界面明确说明 | 脱敏/不可取得状态、下载系统错误分类、最终诊断检查 |
| R9 | 保留唯一构建入口与当前输入 stamp / staging 身份校验 | 最终 Release 构建、stamp 检查；干净构建证据另列 |
| R10 | 不恢复 V1、旧 blob 或缺字段兼容代码；保留既有默认对话备份/转换结果 | 本轮不重复迁移用户库；现有模型/对话/凭据不处理、不删除 |
| R11 | 技术选型 HF 表与 metadata + URLSession 实现同步；用例/存储/诊断/超时与输出边界文档同步 | 文档/源码对照；README 当前验收入口 |

## 资源与职责

- Core 的运行准入按规范路径计数，覆盖多个同时起步调用；删除/unload 持有排他意图，RuntimeCoordinator 的 lease/加载保护仍是实际资源权威。
- DownloadManager 只持有一项 runner、生命周期与变更等待者，以及最多一项未能保存的终态；后者阻止其他下载准入，显式重试可恢复。历史任务留在存储。
- 常规摘要页面 25 项，存储查询最多 100 项摘要；启动恢复及版本家族完整清单逐项读取，文件系统使用游标，不保留全库 manifests 或历史索引。
- 查询列/摘要是同一次提交生成的可重建投影，业务值仍由 payload 解码。缺失投影按有界批次重建；不打开另一份历史 schema 或猜测缺失业务字段。
- 公共输出的累计正文/工具字节上限 16 MiB、工具调用最多 32、单次工具参数最多 64 KiB，由 Core handle 执行；等待缓冲限额另为 128 项/256 KiB。终态在实际停止后报告 resourceLimit/slowConsumer。
- 工具 schema 的结构准入为非空名称、JSON object、顶层 type=object 与字节/数量限制；完整 schema 传给模型，工具执行方按自身业务约束检查参数。Mox 不执行工具或提供通用 JSON Schema 求值器。
- 管理探活保持 15 秒；来源解析/计划/创建与显式加载使用 15 分钟客户端等待期限，取消保持独立短期限。超时不授权重放有副作用请求。

## 最终被测版本与证据

- 分支 `codex/rewrite`，HEAD `c6b7b5d` 加当前未提交工作树（包括本轮之前的收口修改）。没有提交、推送或发布。
- 生产 buildID：`mox-m4-d88127e067682abda153d34763a1ed66ef5c7fe13c4f88d80bea6ac43455fba5`；App 为 `.build/m4/Release/Mox.app`，worker 为其中 `Contents/Helpers/MoxWorker.app/Contents/MacOS/mox`。
- 环境：Apple Silicon arm64，macOS 27.0 (26A428)，Xcode 27.0 (27A266a)。本轮使用现有依赖缓存正常构建，不冒充再次干净检出/无缓存构建。
- `scripts/build-m4.sh Release`：worker/App 两次 BUILD SUCCEEDED，`.build/governance-release.log`；`MOX_BUILD_MILESTONE=m4 python3 scripts/stamp-m3-build.py --check` 与 `git diff --check` 通过。
- 最终生产源码 Core **48** 项通过（`.build/governance-core.log`）；Service **61** 项通过（`.build/governance-service.log`）。测试之后只修改验证脚本与文档，未修改生产输入。包含 F1 阻塞保存竞态、取消/关闭、直接 Core 业务用例、持久重开/真实查询、输出资源限制与 F2 真 socket/F3 草稿故障。
- Sources **7** 项普通回归通过；`MOX_TEST_REAL_SOURCES=1 xcrun xctest .build/xcode/Build/Products/Debug/MoxSourcesTests.xctest` **7** 项通过（`.build/governance-sources-real.log`）。HF Qwen2.5 固定 revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`、MS revision `7b36975ed2397d6eb8fb55cb5a58437bd7ca5b10` 均解析 9 文件并验证实际 config 下载。
- Release GUI 自动化 **2** 项通过：`testM3ConfiguredMirrorSurvivesAcquireSheet`、`testM4APIControls`；日志 `.build/governance-ui.log`，结果 `.build/m4-app/Logs/Test/Test-Mox-2026.09.30_22-54-09-+0800.xcresult`。本次未被锁屏阻塞；不以这两项代替全部 GUI 或用户验收。
- 第一轮最终产物探针已通过 HF 完整 351383618 字节安装、暂停/重启/并发恢复、CLI alias/UUID/逐字段来源、使用中删除 busy 与取消释放、脱敏诊断；SDK 调用因验证脚本解引用虚拟环境 Python 符号链接而未运行。脚本已修正并增加运行前依赖检查，完整矩阵在另一个新根重跑；第一轮不是完整 PASS。
- 一次自动审批因担心 trash 清理误删用户数据拒绝测试启动；核验 Core 测试根均为 temporaryDirectory + UUID 后，重新审查允许执行。最终 E2E 另一次启动因审批服务额度限制未执行，用户要求继续后已成功重试。均未绕过审批，也未使用用户默认根。

### 可复跑入口

```sh
xcodebuild test -workspace .build/m4-package.xcworkspace -scheme MoxCoreTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
# 同样参数将 scheme 换为 MoxServiceTests 或 MoxSourcesTests。
MOX_TEST_REAL_SOURCES=1 xcrun xctest .build/xcode/Build/Products/Debug/MoxSourcesTests.xctest
xcodebuild test -project Mox.xcodeproj -scheme Mox -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/m4-app -skipPackagePluginValidation \
  -only-testing:MoxUITests/MoxUITests/testM4APIControls \
  -only-testing:MoxUITests/MoxUITests/testM3ConfiguredMirrorSurvivesAcquireSheet ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

最终下载/SDK 回归使用 README 的 `verify-source-release.py`，必须指定未存在的 `.build` 子目录，脚本不会清理模型或数据库；停止其自有 worker 后保留证据。SDK 锁定 `openai==3.19.2`、`anthropic==1.8.0`。最终运行命令如下（退出 0、evidence.result=PASS）：

```sh
python3 scripts/verify-source-release.py --app .build/m4/Release/Mox.app \
  --data-root .build/governance-e2e-20260930-final --sdk-python .build/m4-sdk-venv/bin/python \
  --evidence .build/governance-e2e-final.json > .build/governance-e2e-final.log 2>&1
```

- 机器证据 `.build/governance-e2e-final.json`；阶段日志 `.build/governance-e2e-final.log`，worker `.build/governance-e2e-final.worker.log`，SDK `.build/governance-e2e-final.sdk.log`。全部在上述最终 buildID 上运行。
- HF Qwen3 revision `73e3e38d981303bc594367cd910ea6eb48349da8` 完整安装 **351383618** 字节；MS Qwen2.5 revision `7b36975ed2397d6eb8fb55cb5a58437bd7ca5b10` 完整安装 **289598797** 字节，两项均真实 MLX 生成。
- 暂停/进程重启保留任务，两个并发恢复恰好 accepted/busy；进度期间全局保存不丢失；CLI alias/UUID 生成、request/model/global 参数来源均正确。
- 真实生成中删除返回 409；取消返回 202 并等待 activeLeases=0；busy 诊断存在且没有认证内容。
- 官方两家 SDK 文本、流式、工具调用及客户端工具执行往返、流式参数拼接、Anthropic error tool_result 续答、鉴权/Origin/字段/版本/模型拒绝、未消费 body 关闭及读取期限均 PASS。
- 双安装后停止并重启，模型参数/pin 与库恢复，activeDownloads=0；脚本最终已停止自有 worker，保留隔离根，不自动清理。

## 待验证与剩余风险

- 私有镜像、私有仓库真实凭据和 macOS 15 真机：BLOCKED（无对应资源）；凭据事务/来源隔离已用故障注入覆盖，不能替代真实私有端点。
- 恢复逐项读取、内存有界，但启动仍核验受管安装文件摘要；大模型/大库冷启动时延尚无实测，不能宣称常数时延。普通单项操作不依赖该扫描。
- GUI 草稿保留/错误提示/退出选择的完整可见体验仍待人工；独立复核尚未重跑，不能声明已放行。

## 人工验收（未执行）

1. 从最终 `.build/m4/Release/Mox.app` 打开模型页，调整全局/模型参数并验证来源显示；保存期间断开服务，确认编辑窗仍保留输入和错误，重连后可重试。
2. 获取模型时切换页面、暂停并关闭/重开 App，确认任务状态与来源保留；继续下载后测试聊天，复制 alias 用 CLI 生成。
3. 生成中尝试移除模型，确认 busy 与诊断可理解；停止后再次聊天。引用模型移除只删记录，托管删除先核对确认范围。
4. 有活动下载时退出，检查继续/暂停退出选择；导出诊断，服务不可取得时应明确标记，并保留本机报告。

失败证据使用 App 的诊断导出与隔离 worker 日志；不要提供含密钥的 discovery.json。用户实际对话备份与转换沿用上一轮记录，本轮没有再次迁移、删除或读取私人内容。
