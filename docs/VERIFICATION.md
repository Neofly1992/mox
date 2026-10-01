# 首版源码验证记录

## 状态与版本

产品版本 **0.1.0**；源码候选尚未发布。人工体验验收：**待用户确认**。仓库收尾的独立复核：**待执行**。

- `03038c9`：保存已审查的生产修复、正式故障回归及逐轮证据。
- `23184a4`：单独保留更早的 M3 独立复核补记。
- `0b52266`：独立整理提交（正式文档、删除历史材料、统一入口和维护设施）。随后 `e81ee1c`、`38d6bdf`、`0fd0e05`、`fabf0ed` 保存实测发现的工具链、锁文件及测试环境修正；没有升级依赖。

## 历史实现与独立验证

2026-10-01 H1/H2 独立复核确认：Core 52、Service 65 项通过，两处生命周期遗漏关闭；UUID 别名及主要架构治理此前已关闭。历史被测源码指纹 `mox-m4-20e5bda64de91964ed3bedf44a7905ed171fac01f189e74d0a8542cb8d5c01a8`，准确完整指纹及原始报告可从 `03038c9:docs/reviews/h12-independent-2026-10-01.md` 追溯。这些是整理前的独立证据。

旧阶段规格、逐轮报告与重复探针已先保存，再从当前树删除。有效契约归入正式产品、架构及用户文档；没有通过改写文档重新关闭缺陷。

| 旧探针的有效场景 | 正式回归位置 |
| --- | --- |
| 下载并发准入、暂停、失败与恢复 | `Tests/MoxCoreTests/DownloadLifecycleTests.swift`、`DownloadManagerTests.swift` |
| 原子安装后索引失败、索引存在但任务未完成的重启恢复 | `Tests/MoxCoreTests/InstallationCompletionTests.swift`、`RestartCompletionTests.swift` |
| 校验等待期间取消与请求登记 | `Tests/MoxServiceTests/PreparationCancellationTests.swift` |
| 未消费 HTTP body 的错误出口 | `Tests/MoxServiceTests/ServiceTests.swift` 的连接关闭回归 |
| UUID 别名、凭据事务、删除准入与参数保存 | Core 用例测试及 Service 跨入口测试 |
| SwiftData 重开、按身份更新、数据库分页 | `Tests/MoxServiceTests/LibraryStorageTests.swift`、Service 存储测试 |

正式端到端探针保留为 `verify-source-release.py`、`verify-recovery.py`、`verify-sdk.py`、`verify-runtime.py` 和 `verify-package.py`，使用隔离测试数据，不指向用户默认目录。

## 本轮运行

执行者：本实现会话；日期 2026-10-01。环境 macOS 27.0（26A428）、arm64、Xcode 27.0（27A266a）、Swift 6.4。以下是本轮实际运行，不是历史结果。

**最终生产产物**构建提交 `0fd0e05`，产品版本 `0.1.0`，指纹 `mox-49c76ce01a06d50da321a21b058e2bb85d1959b3c2df7d5fcf28932caf269483`。最终测试入口提交 `fabf0ed` 只改测试环境传递及文档版本表述，生产源码与指纹相同。

检出目录 `/private/tmp/mox-source-clean-final-20261001` 初始没有 `.build`；按 README 执行构建，依赖重新检出、编译。发现问题后更新该隔离检出并重建，后续仅复用该检出自己产生的缓存；没有复制原工作区的旧编译产物。最终产物复制到工作区 `.build/Release`，供体验验收。

| 实际入口 / 证据文件（均在 .build，不提交产物或原始日志） | 结果 |
| --- | --- |
| `scripts/build.sh Release` / `repository-clean-build-final.log` | CLI 与 App 构建通过；官方 Metal/bundles 携带完整 |
| 产物元数据核对 / `repository-artifact-identity.json` | CLI、App、worker 均 0.1.0；CLI/worker 指纹相同；App 与根锁文件 33 个 pins 完全一致；内嵌许可证 56 文件 |
| `scripts/test.sh rules` / `repository-rules.log` | Core 52、Service 65 通过；Sources 5 执行通过、2 联网测试 skipped |
| `MOX_TEST_REAL_SOURCES=1 scripts/test.sh rules`（fabf0ed）/ `repository-rules-final.log` | Core 52、Service 65、Sources 7 均实际执行通过；包含 HF 固定 revision 元数据及 MS config 摘要校验，不代表全量下载 |
| `MOX_TEST_MODEL=… scripts/test.sh mlx`（fabf0ed）/ `repository-mlx-final.log` | 9 执行通过、1 未请求性能基准 skipped；真实推理、实际 usage、取消后再次生成、长输入夹具执行；取消等待约 0.0106 秒 |
| `verify-package.py` / `repository-package.json` | 搬移 worker、干净 PATH、仅 loopback 网络、缺资源失败、ad hoc 签名完整性、模型未改；App 主程序无 MLX 符号 |
| `verify-cli.py` / `repository-cli.json` | 真实 TTY、Ctrl-C 后继续、SIGINT 130 / SIGTERM 143、管道/非法参数、Unicode 路径、流式输出、只读模型；取消等待约 0.0077 秒 |
| `verify-recovery.py` / `repository-recovery.json`、`.sdk.log` | 新根复制此前公开测试产物，恢复双源索引、UUID 别名大小写/ID/冲突、真实 CLI 生成、重启参数及 pin；两官方 SDK 文本/流式/工具往返/错误历史及 HTTP body 关闭通过 |
| `scripts/test.sh ui`（下列四项）/ `repository-ui.log` | Release App 四项通过，0 failures；不是完整 GUI 矩阵或人工验收 |
| `python3 scripts/check-repository.py`、`git diff --check` | 文档本地链接、脚本语法、版本/指纹、失效入口及当前跟踪文件检查通过 |

GUI 四项：`testModelWorkspaceEntry`、`testFixtureLongReplyStopRetryAndHistory`、`testPublicAPIControls`、`testMovedAppWithCleanPath`。在独立根生成测试历史；搬移 App 使用临时目录，结束后清理该副本。正式重跑命令见 DEVELOPMENT。

SDK 版本实际核对为 OpenAI 3.19.2 / Anthropic 1.8.0；使用已安装的测试工具虚拟环境，不嵌入产物。恢复测试的来源为 `.build/h12-delivery-e2e/models/artifacts` 的公开测试模型副本；没有重新下载全部权重，也没有打开旧测试数据库或默认用户根。Qwen2.5 夹具 revision/digest 见 DEPENDENCIES，Qwen3 的固定工具能力由实际产物摘要准入。

### 本轮发现与重跑

- Metal 预检最初失败；官方组件下载显示已安装，但默认代理仍报缺失。显式 `xcrun --toolchain Metal metal --version` 可执行，修正入口后构建通过。不要求脚本偷偷下载组件。
- App 首次独立解析选中更高的 swift-crypto；立即停止。生成项目锁文件副本并强制只用 resolved pins 后重建，最终仍为原 4.5.1，33 个 pins 与原仓库一致。
- 首次 MLX scheme 的真实测试因 Xcode 未传环境而 skipped，该次不算真实验证。显式转发 `TEST_RUNNER_` 输入后，真实测试实际执行并通过；Sources opt-in 也已实测。
- Xcode 日志有 CoreDevice/Simulator 插件提示（本轮不使用 iOS simulator），规则临时 SwiftData 夹具清理有 SQLite open-fd 提示；各套测试实际执行并通过。未把这些日志解释为用户库损坏或掩盖测试失败。

### 仓库文件核对

当前提交树没有 App、可执行产物、权重、数据库、Python 缓存、私人会话或检测到的凭据；构建与数据路径由 .gitignore 排除。历史中有一个早期 9176 字节 Python 缓存 blob，当前树已删除；按“不改写历史”的要求保留 Git 追溯，不混入本版源码树。模型权重与构建 App 未发现曾被提交。

LICENSE 保持 MIT / Copyright 2026 Neo；33 个锁定 checkout 顶层许可证逐一核对，嵌套声明递归携带。原始日志/测试数据继续保留在忽略的 .build，下面的摘要哈希帮助核对本机证据；Git 中保存本记录及历史报告，而不提交二进制和测试库。

## 限制与人工体验

- macOS 15 是部署目标，尚未真机验证；当前环境为 macOS 27 / Apple Silicon / Xcode 27。
- GitHub CI 配置已依据官方 runner 和 Xcode 清单设计，但远端运行尚未发生。规则测试不等于真实 MLX、GUI 或官方 SDK 验证。
- 本次不做签名、公证、Homebrew、二进制发布或默认用户数据操作。
- 本轮未重新执行双源全量网络下载、完整 GUI 矩阵、真实私有来源/镜像、超大模型库耗时、全部模型架构或性能基准。`verify-source-release.py`、`verify-runtime.py`、`benchmark-history.py` 本轮只检查语法/帮助入口，不把它们的历史执行当作新通过。
- 干净构建、最终模型/API/CLI/GUI 定向路径已经实测，无当前环境阻塞的必需基础验证；上述未验证范围须由独立复核和用户决定发布取舍。

用户体验验收（自动验证完成后再进行）：

1. 打开最终 App，检查模型库、来源设置和测试页是否容易理解；导入已有模型时确认显示为引用。
2. 发送消息、观察流式输出，取消后再次发送；检查历史重开和重试分支体验。
3. 查看下载任务的暂停/继续反馈及参数编辑；启用本机 API 后检查地址、密钥和关闭操作是否清楚。

以上只评价体验，不要求用户排查基础正确性。未收到用户反馈，不填写“已验收”。

## 本机证据摘要 SHA256

```text
0978b819402166c6d1a8b32639ff99c51993c883ab12bd307e4dd1bea548eb90  repository-clean-build-final.log
fcee2fc85af988e1e919b2006297b6dcb8535888219477b0907976f8eab36b84  repository-rules-final.log
3c104eedf870df4971d6109d92d9532d9cf07c8fbe33881215e3b15e0a22b83c  repository-mlx-final.log
255c866293aeed4607631556e0512960ff21065901a83bf22d25bd9adaa07c96  repository-ui.log
03d4ead2f9256350a22d69b4e05d185252ecab4313b4dc3d1f185a73dcb92dff  repository-artifact-identity.json
38f134de88907cc4ec0dad6a9aaa92bb7156f06dc9c3167404ccd64e3a3d6830  repository-package.json
3da95e301022a6ea6c3bde6859d77c52a70499e8097a6e90efc0142eaff9d629  repository-cli.json
fe0f55e5ed0d8b20d07826a1b3b51c870d26b60079d45cc24b278b1a6e121d01  repository-recovery.json
bda2af31e9807cee196d05d02176aa6c107dbd59650a200fb696709ec646fbcb  repository-recovery.sdk.log
```
