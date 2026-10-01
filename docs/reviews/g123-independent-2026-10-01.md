# G1–G3 独立定向复核（2026-10-01）

基线：`codex/rewrite` / `c6b7b5d` 加未提交工作树，生产 buildID `mox-m4-7626f190970d727f5fabc613d1ac85eef6e0e4d4f08462fa9f7e59d57537b2a0`。保留已有修改，本轮未改生产源码/用户数据、未提交推送。临时探针运行后已移回审查目录。

## 结论

**G2 可关闭；G1/G3 的主要实现有效，但各有一处原范围内的遗漏，尚未放行。** A1/A2/F1–F3 不重新打开，也不要求新一轮泛化重构。

## H1 / P1：校验中的生成请求尚未注册，无法及时取消

位置：`Sources/MoxServer/Service.swift:221–227,500–502`，`Sources/MoxCore/ModelLibraryService.swift:265`，`Sources/MoxClient/ServiceClient.swift:152–165`。

Server 先 await library.generate，Core 又先 await verifyInstallation；完成后才取得 handle、登记 states/handles 并挂连接关闭处理。校验期间 seen 已消费该 requestID，但服务状态不含它，cancel 查不到它。客户端只为短注册竞态重试约 15 秒，无法承担任意长度的完整性校验。流的响应/heartbeat 也在此 await 之后才开始；因此将服务探活与校验分开尚未闭合请求自身的可见、取消与等待生命周期。

本轮使用真实 HTTP 与可控慢 verifier：确认本次生成调用已经进入 inspect 后，state.requests 不包含 requestID；cancel 明确返回 notFound。随后由测试显式 shutdown manager 释放任务，未冒称取消请求成功。两个断言失败。原慢恢复测试检查了探活、健康模型和全服务 shutdown，但未检查用户停止正在校验的单个请求。

修复应在耗时准备前建立可见、可取消的请求生命周期，把校验作为 preparing/checking 阶段。取消本请求应停止其等待和后续生成，不能取消其他请求/后台恢复共用的校验；取消完成后不可再悄悄进入 runtime。流式等待应有正常 heartbeat/超时契约。不要只延长客户端注册重试或 generation timeout。补单请求取消、共享校验一个等待者取消、断开连接、长校验、停止后再次生成的定向验证。

## H2 / P2：安装索引已存在时，重启不补任务终态

位置：`Sources/MoxCore/DownloadManager.swift:733–746,825–837`。

recoverCommitted 先提交 installations，再逐条提交 operations；两次提交之间可发生退出/故障。启动恢复却只有 installation 不存在时才进入 recoverCommitted，已存在就跳过。因此“安装记录已落盘，任务终态未落盘”不会被启动恢复补全，模型与任务列表可长期分别显示 ready 与 failed/interrupted。

本轮沿用正式 G1 的 failAfterSaving 故障，只将恢复动作从同进程 resume 改为重启：提交前失败分支通过；安装索引已保存但抛错的分支恢复后 phase 仍 failed，预期 installed 的断言失败。已有同进程显式 resume 会补全，因此不宣称数据永久损坏；缺的是重启路径的幂等完成。

修复：在不破坏分页和资源边界的前提下，让安装索引及关联任务终态形成完整持久事务，或确保启动恢复会校对并补全已有索引的未完成任务。不能用“索引存在”代表整笔完成已提交。覆盖 installation 已存在 + committing/interrupted/failed、完成提交结果不确定，以及 manifest 冲突不得伪装 installed。

## 已确认的改善

- G1 同进程重试现在检查已提交产物并复用完整性确认与索引补全，不再重新下载；损坏与冲突拒绝有回归。H2 是该步骤跨持久提交/重启的组合遗漏。
- G2 UUID alias 规范键与冲突规则已统一。本轮最终 Release 原失败探针：导入 200、UUID alias 查询 200、实际安装 ID 查询 200；Service 大小写/冲突回归通过。
- G3 管理 listener 可先探活、校验在 actor 外且可由 manager 关闭；原超过 15 秒仍探活、健康模型按需校验、设置不被覆盖等测试通过。H1 是生成请求登记在校验之后的遗漏，不否定服务启动治理。

## 独立证据

- 当前源码 Xcode Core：50 项通过，`.build/review-g123/core.log`。
- 当前源码 Xcode Service：原有 64 项通过；临时加入的 H1 探针两断言失败，共 65 项测试、1 项失败。`.build/review-g123/service.log`。
- 原样 Core 隔离包 H2 参数化探针：提交前失败分支通过，已保存后抛错分支失败。`.build/review-g123/restart.log`。
- 当前交付 Release UUID alias 原探针通过，`.build/review-g123/alias.json`。临时根、自有 worker，用后停止并清理；未读写用户默认库。
- stamp --check 与 git diff --check 通过。生产身份未改变。
- 探针保存在 [probes/g123-2026-10-01](probes/g123-2026-10-01/README.md)。规则测试使用 `.build/m4-package.xcworkspace` 的 Core/Service scheme，Debug、arm64、`.build/xcode`、CODE_SIGNING_ALLOWED=NO。

本轮没有重复全量真实模型/SDK/GUI/Release 构建，相关实现者证据仍以定向验收报告为准，不冒称独立运行。人工验收、超大库耗时、真实私有端点和 macOS 15 状态不变。

下一步仅修 H1/H2，建立上述相邻状态组合回归，再定向复核。无需再次讨论已认可架构或扩大首版功能。
