# 首版 G1–G3 定向收口验收（2026-10-01）

> 阶段历史：后续独立复核发现 H1/H2；最新实现者修复及修改后证据见 [H1/H2 报告](source-release-h12-2026-10-01.md)。本报告的通过项不替代新版本验证或独立放行。

状态：实现与本机自测完成，待独立定向复核和用户验收；不宣布首版放行。上轮 F1–F3/A1/A2 的主要整改已获独立认可，本轮只修具体边界。最后幂等补充前的 68c137f… 产物证据保留为阶段验证，本文交付证据仅对应下述 7626f190… 版本。[独立报告](../reviews/governance-independent-2026-10-01.md)保持原样，[上轮证据](source-release-governance-2026-09-30.md)为历史记录。

## 实现与验收映射

| 项目 | 本轮实现 | 新证据 |
| --- | --- | --- |
| G1 | 显式重试和启动恢复共享完整性确认及幂等索引补全；先检查已提交目录、来源/manifest/实际字节，提交安装与任务终态；目标损坏/冲突不下载、不删除、不猜测成功 | 原失败探针正式纳入 InstallationCompletionTests：同进程索引保存失败及已落盘但报错重试成功、获取次数不增加；重启补全、损坏与 manifest 冲突拒绝。Release 从双源完整产物恢复索引 |
| G2 | ModelIdentifier.aliasKey 统一 UUID 拼写；非 UUID 别名仍大小写敏感，展示值保留。导入/托管安装生成 ID 检查 alias/ID 冲突，读取同时查询两种身份，歧义明确 busy；SwiftData 索引按规范键查询，已有 payload 不改写 | UUID alias 原/大写/实际 ID 均成功；与另一 ID 冲突导入拒绝；已有歧义数据拒绝，不误选或删除；最终 CLI 三种标识均真实生成 |
| G3 | 先建立父控制/退出，再发布可探活 listener，后台恢复任务由 Core 拥有。libraryRecovery 与 checking 表达恢复/模型状态；校验 IO 在 actor 外，最多两项、同模型共享；本进程校验凭证才允许推理，路径必须绑定产物身份，未建索引托管路径不能伪装引用 | 可控慢校验超过原 15 秒仍能 HTTP identity/state；未校验模型无 lease，另一健康受管模型按需校验并生成；停止取消恢复。校验期间参数保存不被覆盖；Release 约 641 MB 双源产物恢复、重启/按需生成与父 EOF 关闭 |

恢复期间删除返回 busy，且在 runtime 卸载前检查，避免删除与索引补全相撞。校验失败保留文件和记录，显示 corrupt 或恢复失败并导出安全诊断；停止取消并等待自有校验。没有延长 15 秒服务探活期限。

## 最终被测版本

- `codex/rewrite`，HEAD `c6b7b5d` 加当前未提交工作树；保留原收口修改与评审材料，没有提交/推送/发布。
- buildID：`mox-m4-7626f190970d727f5fabc613d1ac85eef6e0e4d4f08462fa9f7e59d57537b2a0`。
- App `.build/m4/Release/Mox.app`；worker `Contents/Helpers/MoxWorker.app/Contents/MacOS/mox`；最终 stamp --check 与差异检查通过。
- macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、arm64。使用现有依赖缓存构建，不声称干净检出/无缓存。
- 测试后仅修改测试数据生成器、UI 测试、验证脚本和文档；生产身份未变。未读写用户默认对话、模型或凭据；上轮已授权对话备份/转换不重复处理。

## 实际测试

| 执行 | 结果与证据 |
| --- | --- |
| 最终 Core suite | **50 项 PASS**，`.build/g123-core.log`；G1 参数化提交前/已落盘报错及 clean/damaged/conflict 均通过 |
| 最终 Service suite | **64 项 PASS**，`.build/g123-service.log`；慢恢复测试约 16 秒，明显超过原探活期限 |
| `scripts/build-m4.sh Release` | worker/App 两次 BUILD SUCCEEDED，`.build/g123-release.log` |
| 最终产物定向 E2E | **PASS**，`.build/g123-delivery-e2e.json`、同名 `.log/.worker.log/.sdk.log` |
| GUI | **最终 Release 两项 PASS**：testModelWorkspaceEntry / testM4APIControls，`.build/g123-ui-delivery.log`；首次失败和 fixture 修复见下文 |

最终 E2E 命令：

```sh
python3 scripts/verify-governance-boundaries.py --app .build/m4/Release/Mox.app \
  --source-root .build/governance-e2e-20260930-final \
  --data-root .build/g123-delivery-e2e --sdk-python .build/m4-sdk-venv/bin/python \
  --evidence .build/g123-delivery-e2e.json --check-prior-store
```

它从上轮已验证的隔离测试产物 clone 到全新测试根（不是重新下载的证据），恢复两项安装并使用真实 MLX 推理。HF Qwen3 固定 revision `73e3e38d981303bc594367cd910ea6eb48349da8`、351383618 字节；MS Qwen2.5 revision `7b36975ed2397d6eb8fb55cb5a58437bd7ca5b10`、289598797 字节。服务首次健康就绪约 0.093 秒，记录 recovering→ready；不据此推断超大库耗时。UUID alias 原拼写/大写/实际安装 ID 的 CLI 真实生成和冲突拒绝 PASS；官方 `openai==3.19.2` / `anthropic==1.8.0` 文本/流式/工具往返与错误矩阵 PASS；重启后的参数/pin 与按需受管模型生成 PASS；父控制 EOF 停止自有进程 PASS。最后另打开上轮隔离 runtime 数据库，安装、参数和 pin 保留、两项 ready。此验证没有操作真实用户库。

一次 Core 重跑因与 Release 构建共享 Xcode build.db 而未启动测试；改为串行后最终 Core 与 Service 均 PASS，不把数据库锁错误算产品测试失败或通过。

规则命令沿用上轮 `.build/m4-package.xcworkspace`、Debug、arm64、`.build/xcode` 与 CODE_SIGNING_ALLOWED=NO，scheme 分别为 MoxCoreTests/MoxServiceTests。Xcode 输出包含 CoreDevice/CoreSimulator 版本不匹配提示，但本机 macOS 测试实际执行并通过；不据此声称 iOS 测试可用。

GUI 第一次失败揭示测试入口陈旧：seed 指向 9 月 23 日旧 MoxTestSupport，而且只播种对话，不播种已成为工作台权威的服务模型目录。已改为当前 Xcode 构建产物，在临时根通过 Core 创建合法引用记录，工作台测试选择 installedModelDetails。没有为让旧 fixture 可读而恢复对话 V1。复跑前构建测试工具：

```sh
xcodebuild build -workspace .build/m4-package.xcworkspace -scheme MoxTestSupport \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Mox.xcodeproj -scheme Mox -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/m4-app -skipPackagePluginValidation \
  -only-testing:MoxUITests/MoxUITests/testModelWorkspaceEntry \
  -only-testing:MoxUITests/MoxUITests/testM4APIControls ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

## 限制与下一步

- 独立定向复核未执行；人工验收未完成。不要改写独立报告宣布关闭。
- 未新造超大真实库或模拟生产环境长耗时；超过期限的验证来自受控慢 IO + 实际 HTTP，合理规模来自 640982415 字节双源真实产物。两者分开记录。
- 私有端点真实凭据、macOS 15 仍 BLOCKED。上轮双源网络下载/GUI 镜像配置证据未当作新版本重跑。
- G1 无损坏自动覆盖/删除策略：目标损坏时拒绝并保留，用户通过已有删除/重新获取操作恢复；已有数据不自动处置。
- 复跑脚本只接受仓库 `.build` 测试根；新目标目录必须不存在，测试文件保留，由开发者核对路径后自行清理。

## 人工验收（未执行）

1. 用最终 App 查看服务已连接与模型 checking 状态，选择另一健康模型测试；观察开始前的校验提示与失败诊断是否清楚。
2. 导入本地引用并使用 UUID 形式别名，以 GUI 复制的标识在 CLI 生成；相同标识查询应一致，冲突导入应明确拒绝。
3. 获取任务保存失败后恢复存储条件并点击继续，应完成安装；若目标文件损坏，应保留数据并提示失败，不重复下载或伪装成功。自动故障已覆盖，不要求用户人为破坏数据来验收。

独立会话先读 HANDOFF、原则及本报告，再检查实际源码与上述日志/机器证据，重点复核 G1 共享幂等完成、G2 命名空间一致、G3 健康与完整性生命周期分离；无需重开已认可的泛化架构讨论。
