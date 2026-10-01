# 首版源码收口独立复核

日期：2026-09-30。基线为 `c6b7b5d` 上的未提交收口工作树；生产 buildID `mox-m4-a2a2c569cf0a2f690482af2e6f0e4b29a5d7a48b386bc8ad3a241c61a2bba812`。本轮保留全部已有修改，仅添加评审证据和更新交接；不修改生产代码、不提交或发布。

## 结论

**尚未通过独立复核。多数修复有效，但不能认定只剩 GUI 人工验收。** 需要继续修复下载操作准入、HTTP 提前拒绝和参数编辑失败行为，并完成原评审中尚未落实的业务职责整理。无需再次重写工程。

本报告 F1–F3 是当前具体缺陷，与前次 R1–R11 编号分开。A1/A2 分别记录仍待完成的职责要求和已改善但未完全解决的存储问题。不能以本报告代填用户验收。

## F1 / P1：并发 resume 可启动两个写同一暂存目录的 runner

位置：`Sources/MoxCore/DownloadManager.swift:311–317`，并关联 pause/cancel/shutdown 的所有权。

新的 mutation gate 串行化了保存，但 `resume` 的 `runners.isEmpty` 与 phase 准入判断在 `await transition` 之前。第一个请求等待持久化时，第二个请求看到的仍是 paused 和空 runners，因此也通过检查。等待结束后没有复核或预留 runner，两个请求均启动 `execute`，后一项覆盖 `runners[id]`，两个任务却都还在运行；其 defer 还可能相互清掉 runner 记录。可能并发写同一暂存文件、失去取消/关闭对所有任务的控制。

本轮故障注入：阻塞第一次 downloading 保存，发起第二次 resume，再放行。两次请求均成功，传输方法实际调用两次；“应只接受一次、只传输一次”两项断言失败。原有 39 项 Core 测试通过。探针见 [probes/2026-09-30](probes/2026-09-30/README.md)。该结果并不否定原配置保存撞进度的回归已修好，而是说明根因只处理到保存层。

修复应统一完整操作生命周期的准入、状态发布、runner 预留和撤销。不要只在等待前加一次检查或用延时回避；同时补 resume/resume、resume/cancel、停止与正在准入的任务相撞的测试。单一下载的所有权必须在首个可重入点前成立，失败时回滚。

## F2 / P2：仍有私有提前拒绝路径绕开连接关闭策略

位置：`Sources/MoxServer/Service.swift:455,543–549,674–681`。

`bodyReadInProgress` 初值 false，只在进入 reader 前设 true。下载接口还保留旧 Content-Length 超限检查，直接 throw 时标志仍为 false；模型 sampling/pin 则在读取 body 前查安装，未知 UUID 的 404 也走同样路径。catch 返回错误却不关闭仍有未消费 body 的连接。代码抽出了 reader，但连接生命周期仍由每条业务分支手工维护，因此继续漏掉边界。

交付 Release 的独立真 socket 结果（管理凭据来自本轮隔离 worker，未泄露）：

| 请求 | 响应 | 3 秒内关闭 | Connection: close |
| --- | --- | --- | --- |
| import，超限未终止 chunked | 413 | 是 | 有 |
| downloads，Content-Length 16385，不发送 body | 413 | 否 | 无 |
| 不存在 UUID 的 sampling，未终止 chunked | 404 | 否 | 无 |

当前已有 15 秒 idle 策略，所以这里不宣称永不关闭或未鉴权漏洞；问题是提前拒绝未落实主动释放规则，且 reader 的整体读取期限没有覆盖这些路径。

应按“请求 body 是否已完整消费”管理错误出口，而非“是否正在执行 reader”；删除重复长度预检，覆盖业务查找失败、不可用服务、未知路由和大小错误。现有 Service 54 项全通过仍不足以证明所有入口关闭策略一致。

## F3 / P2：参数保存失败也关闭编辑窗并丢失输入

位置：`App/WorkspaceView.swift:376–419`、`App/LibraryController.swift:117–141`。

编辑器 save 闭包返回 Void，controller 捕获保存冲突/存储错误后也正常返回；编辑器始终 dismiss。因配置 revision 冲突、断连或存储失败未保存时，用户输入被丢弃，只能在底层模型页看到错误后重新输入。保存期间按钮也未禁用，重复点击可因 busy 直接返回而提前关闭窗口。

这是源码确认的控制流，本轮没有将 GUI 实测记为通过。保存动作应返回成功结果或抛错，只有成功才关闭；失败保留草稿并在编辑窗展示恢复入口，提交期间避免重复提交。通过故障注入/控制器测试验证，不应让用户承担这个基础正确性检查。

## 原审查逐项状态

| 原项目 | 本轮判断 |
| --- | --- |
| R1 | 原配置保存/进度相撞路径通过；生命周期仍未闭合，见 F1 |
| R2 | 显式失败重试/资源释放回归通过；源码已增加失败清理。不能把它描述为所有加载等待者已统一重构 |
| R3 | 原 import/API 超限读路径已有共享规则；仍未完全关闭，见 F2 |
| R4 | 已改为 ServiceState 全量活动下载计数，相关测试通过；可见退出提示仍待人工 |
| R5 | 模型页现展示 library.error，轮询不立即抹掉错误；可见体验待人工 |
| R6 | 明确 CLI --model/--model-path，GUI 提供 alias 复制，入口修复合理；本轮未重复真实 alias 生成 |
| R7 | 新增跨管理操作和下载终态安全事件，域名白名单与导出边界有改善；诊断请求失败被 try? 压成空 events 仍宜显式显示“服务诊断不可取得”，不能伪装没有事件 |
| R8 | 参数逐字段解析、来源、持久设置、pin、启动限制确有实现和规则测试；GUI 编辑失败须修 F3 |
| R9 | stamp 校验覆盖当前生产输入，staging 身份比较会拒绝陈旧 worker；README 给出唯一入口，方向正确 |
| R10 | 生产 V1/schema migration 和旧 blob 入口已删除；正式版本号 2.0.0 与固定列名不等于保留双实现，可接受。默认库备份/转换是实现者证据，本轮不重新迁移或读用户内容 |
| R11 | README 和多数状态、默认行为冲突已修；技术设计选型表仍写 HF“快照下载/cache/恢复”，与 §4 metadata + URLSession 不一致，应同步 |

## A1：业务用例仍留在 Server，不能仅改名为后续风险

`InferenceService.response` 仍直接编排 registry 凭据创建/提交/回滚、模型删除准入、pin 的 runtime/持久状态协调；`resolvePull` 与 `resolveSampling` 也位于 Server。新 pin 功能继续扩充这一模式。Core 提供的 removeInstallation 本身不执行 runtime 的使用保护，完整安全删除只有经过 HTTP 路由才成立。

这与已确认的“共享用例放 Core，Server 提供协议适配”不一致，不只是文件长的风格问题。未来 CLI/GUI 以外调用 Core 会缺失相同业务保障，关键事务必须通过 HTTP 测试，路由修改同时影响凭据和运行状态。能力白名单移入 Core 是改善，但未完成主要用例边界。

本次收口应将来源配置事务、模型设置/删除等有明确所有者的用例迁至 Core，通过现有 ports 注入持久化、来源凭据和 runtime；Server 只做 DTO、鉴权、HTTP 生命周期和调用。可按实际业务组件拆分，不另造万能 service 或大量纯转发类型。此项是原评审要求的剩余工作，不要求重做 MLX/GUI/整个仓库。

## A2：存储高频更新已改善，全量库仍是主要操作单位

`RuntimeStore.saveOperation` 已按 ID 查询/写入，原高频进度全库 diff 问题得到实际改善。`readLibrary/saveLibrary` 仍全量载入和 diff，配置/pin/采样设置也 fetch 所有 installation/operation；DownloadManager 保持完整 snapshot。不能说整体已完成有界查询。

尚无真实大库性能故障证据，本轮不据此编造 P1。建议随 A1 明确按身份的配置/安装更新与摘要查询 ports、事务边界；若暂时保留全库索引，需给出容量约束及对应测试依据，而不是仅写“以后测量”。不需要更换 SwiftData。

## 独立证据与限制

- 当前源码 Xcode Service suite：54 项通过，日志 `.build/review-20260930/service.log`。
- 原样复制当前 Domain/Core/CoreTests 到隔离包：39 项原测试通过；新增 F1 探针失败，两项断言。日志 `core.log`、`race.log`。隔离包没有替换被测生产逻辑。
- 真 socket 使用交付 App 内嵌 worker、全新临时根，结果 `http.json`；测试后停止自有进程并清理临时根。没有操作用户实际服务或密钥。
- `git diff --check` 与源码 stamp --check 通过；本轮按 README 复跑 Release 构建，结果补记于下。
- 本轮没有重跑全部 SDK/真实模型/真实来源矩阵；实现者报告的这些结果保留为实现者证据。GUI 自动化、人工体验、私有镜像和 macOS 15 不由本轮代填通过。

下一步仍是修复和定向复核，之后再进入最终 GUI 人工验收。发布不需要等签名、公证或 Homebrew。

### Release 构建补记

按 README 执行 `scripts/build-m4.sh Release`，worker/App 两次 **BUILD SUCCEEDED**，命令退出 0；日志 `.build/review-20260930/build.log`。生产 stamp 校验仍为 a2a2c569…ba812。本轮使用当前工作区的正常增量依赖缓存，不冒充再次干净检出或无缓存构建。生成器没有引入新的生产源码差异。
