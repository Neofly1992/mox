# M3 独立阶段审查（2026-09-24）

结论：下载、安装、模型管理的主体实现已经建立，但本轮发现两项实测 P1 和一项代码确认的 P2；M3 回到实现中，先修复再交正式人工验收。不建议进入 M4，也不需要推翻整个工程。本文独立于实现者的 `M3-2026-09-24.md` 自审。

## 审查对象与验证

- `codex/rewrite`，HEAD `d581730cc84f62928b3027e91a804bf81fdca625`；包含未提交/未跟踪的 M2、M3 文件。没有修改生产代码、提交或推送。
- 独立重算生产源码指纹为 `mox-m3-89dc789048e7bba6e1532e81ae10854587cd2e624f688aad01979d2c3fcb8758`，与交付报告一致。
- 阅读工程原则、贡献流程、M3 规格/报告/自审，重点检查 DownloadManager、ArtifactStore/Validation、来源与传输、RuntimeStore、私有模型管理接口、CLI 生命周期、GUI 获取调用。
- 本轮实际执行 `swift test --scratch-path .build/m3-fix-tests --filter 'MoxCoreTests|MoxSourcesTests|MoxServiceTests'`，74 项通过（7 来源、36 服务、31 核心），日志 `.build/m3-independent-review-tests.log`。这不是实现者报告的 81 项全量复跑，不含 GUI 自动测试及 MLX/Unicode 测试。
- 额外使用交付 Release CLI 和隔离临时目录做了以下两项复现；原始记录位于 `.build/m3-independent-cli-probe.json` 与 `.build/m3-independent-recovery-probe.json`。测试副本已清理，未改原模型或用户数据。本轮未重新完整下载双源模型、复跑 GUI 或验证私有镜像。

## R1 · P1：CLI 自启服务后提交下载，立即关闭其 worker

位置：`Sources/MoxCLI/Models.swift` 的 `Pull.run`（约 81–86 行）和 `DownloadAction.run`（177–181 行）。

`Connection.open` 在没有现成服务时启动己方 worker。`pull` 只提交任务、打印 UUID 就返回，defer 随即 requestStop；worker 的 shutdown 会取消下载。resume 使用同样的生命周期开关。用户得到退出码 0，却不能仅靠这个命令完成下载。已有真实测试脚本先显式启动长期服务，因而未覆盖这条路径。

实测：全新临时 data root，执行交付 CLI 的 `models pull --provider huggingFace --repository mlx-community/Qwen2.5-0.5B-Instruct-4bit`，返回 0 和任务 UUID；两秒后执行同 root 的 `models list`，该任务为 `interrupted`，没有安装记录。

修复方向：明确短命 CLI 与持久任务的所有权。自启 worker 的 pull/resume 至少应保持前台等待至完成或显式暂停/取消，并正确报告失败；已有外部服务时遵循不误停服务的契约。不为修复此问题暗中引入另一套系统常驻服务管理。共享生命周期应由一处实现，不在各子命令复制轮询/停止逻辑。

验收：无服务的干净 root 下，真实 pull 可完成安装，resume 可完成恢复；中断和失败退出码/持久状态正确。另验证连接已有服务时 CLI 退出不取消其他任务。不能只验证 HTTP 返回任务 ID。

## R2 · P1：单个已安装模型缺文件会阻断整个服务启动

位置：`Sources/MoxCore/ArtifactStore.swift:145–162`，`Sources/MoxCore/DownloadManager.swift` 的 recover，以及 `Sources/MoxCLI/Serve.swift:47`。

启动在发布服务地址之前执行 recover。`committedManifests()` 对所有安装全文校验；任何一个文件缺失、digest 不符或 manifest 损坏都会直接抛出，继而使整个 serve 退出。现有 missing 分支只能覆盖目录完全不存在，不能处理目录仍在但少一个文件的常见损坏状态。结果不仅坏模型不可用，健康模型、下载管理和删除入口也全部不可用。

实测：将已经验证的 HF 安装复制到临时 root，首次启动成功且退出码 0；仅删除副本中的 `tokenizer_config.json`，再次启动不发布 discovery，退出码 1，日志提示文件不存在。原安装未被改动。

修复方向：区分全库元数据不可读与单个 artifact 损坏；后者应保留记录、呈现 missing/corrupt 与可诊断原因、拒绝加载，并允许通过正常管理路径移除/重新获取，健康模型和服务继续工作。不能静默忽略损坏或把它标 ready。顺便拆开启动索引恢复与全量权重校验：当前每次启动重新 hash 并 fsync 所有模型，启动成本随全部权重增长，可能超过 GUI 15 秒启动期限；本轮未测大模型启动阈值。

验收：两个安装中一个缺文件/错误 hash/损坏 manifest，服务仍可启动、健康模型可用，坏模型明确不可加载且能安全移除。覆盖空目录与目录完全丢失，并验证 rename/save 崩溃修复不受影响。

## R3 · P2：模型库全量响应与客户端 1MiB 限额冲突

位置：`Sources/MoxServer/Service.swift:269–271`、`Sources/MoxClient/ServiceClient.swift:320–326`；关联 `ModelLibrarySnapshot` 和 RuntimeStore。

模型库接口每次返回所有安装和历史任务，每项都包含完整文件 manifest；没有分页或响应总量准入限制。安装后任务仍保留，所以同一份 manifest 同时出现在 installation 和 operation。客户端对所有 JSON 响应统一使用 1MiB 上限，而单份合法 manifest 本身允许最多 10,000 文件/8MiB。合法库增长或一个较大的文件清单就能让 library() 报 protocolViolation。GUI 刷新、CLI 来源配置和获取、删除/任务操作响应均依赖该全量快照，因而会连带失效。此项由边界和调用关系确认，本轮未构造超限库端到端复现。

修复方向：分离模型/任务摘要、配置和 manifest 详情，按需分页并定义每个接口的有界契约；内部持久化也避免每次文件进度更新编码整个模型库。不要简单取消客户端限额或不断扩大常量。SwiftData 应承载有明确身份的记录及查询，而不只是装整个不断增长 JSON 的单行容器。

验收：覆盖总元数据大于 1MiB 的合法库和较大清单，确认列表、进度、配置与删除持续可用，响应及客户端内存有界，单项详情有明确分页/大小策略。

## 出口与验证缺口

报告诚实标出了私有镜像、物理断网、真实 MLX 推理中删除、多进程配置联测及 Release GUI 未测，这一点应保留。但可自动完成的真实 lease/双客户端与交付 Release 验证，应由实现会话补齐，不能整体转交用户承担基础正确性排查。真实私有源缺资源则明确列依赖和阻塞；依据 CONTRIBUTING 的出口要求，不能用“可试用候选”替代必需项完成。

先修 R1–R3，补针对性回归和受影响的真实链路，刷新证据后独立复核；用户再验收交互体验。模型库查询/持久化边界需要局部整理，其余已验证的 Core/运行资源/来源适配可以保留，无需整库重写。
