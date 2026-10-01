# 首版源码验证记录

## 状态与版本

产品版本 **0.1.0**；源码候选尚未发布。人工体验验收：**待用户确认**。仓库收尾的独立复核：**待执行**。

- `03038c9`：保存已审查的生产修复、正式故障回归及逐轮证据。
- `23184a4`：单独保留更早的 M3 独立复核补记。
- 本轮整理与最终构建版本、实际测试结果将在执行后补齐；不把历史通过当作本轮结果。

## 历史实现与独立验证

2026-10-01 H1/H2 独立复核确认：Core 52、Service 65 项通过，两处生命周期遗漏关闭；UUID 别名及主要架构治理此前已关闭。历史被测源码指纹 `mox-m4-20e5...`，准确完整指纹及原始报告可从 `03038c9:docs/reviews/h12-independent-2026-10-01.md` 追溯。这些是整理前的独立证据。

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

待执行干净检出构建、规则回归、产物入口验证和文档/版本检查。尚未运行项不得解释为通过。

## 限制与人工体验

- macOS 15 是部署目标，尚未真机验证；当前环境为 macOS 27 / Apple Silicon / Xcode 27。
- GitHub CI 配置已依据官方 runner 和 Xcode 清单设计，但远端运行尚未发生。规则测试不等于真实 MLX、GUI 或官方 SDK 验证。
- 本次不做签名、公证、Homebrew、二进制发布或默认用户数据操作。
- 真实来源联网测试、完整 GUI 与完整模型覆盖按实际运行范围记录，不从历史推定。

用户体验验收（自动验证完成后再进行）：

1. 打开最终 App，检查模型库、来源设置和测试页是否容易理解；导入已有模型时确认显示为引用。
2. 发送消息、观察流式输出，取消后再次发送；检查历史重开和重试分支体验。
3. 查看下载任务的暂停/继续反馈及参数编辑；启用本机 API 后检查地址、密钥和关闭操作是否清楚。

以上只评价体验，不要求用户排查基础正确性。未收到用户反馈，不填写“已验收”。
