# 首版源码发布 H1/H2 定向收口（2026-10-01）

状态：实现者自测完成项见下表；独立定向复核及人工验收未完成，不能据此宣布首版放行。范围仅为[最新独立报告](../reviews/g123-independent-2026-10-01.md)的 H1/H2，不重新展开已认可的 A1/A2/F1–F3 或 G2。已有修改与用户数据保留，未提交、推送或发布。

## 修复与验收映射

| 项目 | 根因处理 | 回归与实际证据 |
| --- | --- | --- |
| H1 / G3 | Server 在耗时校验前登记请求/可取消句柄；Core 让句柄拥有准备、校验等待、后端执行和实际停止。同步元数据错误仍保留 HTTP 错误状态。共享校验由模型库拥有，一个等待者取消只退出自己的等待，不中止其他请求/后台恢复；shutdown 才取消库级工作。取消后不进入 Runtime，流等待期间有心跳，连接关闭绑定覆盖准备阶段 | `PreparationCancellationTests`：17 秒 verifier，校验时状态可见、单请求取消 2 秒内结束、未进入 Runtime、另一个等待者仍成功、只调用一次 verifier、再次生成成功；记录后端 requestID 排除取消/断连请求在校验后启动；真实 socket RST / FIN 两种分支均通过，FIN 在心跳写入检测窗口内结束。现有慢恢复超过 15 秒仍探活、shutdown 回收、慢读/不读与取消复用回归通过 |
| H2 / G1 | 启动恢复不再把“已有安装索引”当作整笔安装完成；核对未完成任务的完整 manifest/身份/字节后，复用正常重试的幂等补全。分别持久化索引和任务的中间状态可恢复，维持分页/按身份查询边界 | `RestartCompletionTests`：索引提交前失败、已保存后抛错；已有索引 + committing/interrupted/failed，清除任务错误、补齐字节数、保留 ID/alias/pin/参数，再重开幂等；同三个状态的冲突计划拒绝 installed。原正常重试、损坏/冲突产物与下载并发回归也通过 |

技术契约更新于[技术设计 §6](../architecture/TECHNICAL-DESIGN.md)、[M2](../milestones/M2.md)和[M3](../milestones/M3.md)。不变更产品范围、重要默认值或磁盘 schema，不转换或删除现有数据。

## 最终被测版本

- 分支 `codex/rewrite`，HEAD `c6b7b5d` 加已有未提交工作树，以生产源码指纹识别本轮产物。
- buildID：`mox-m4-20e5bda64de91964ed3bedf44a7905ed171fac01f189e74d0a8542cb8d5c01a8`。
- App：`.build/m4/Release/Mox.app`；嵌入 worker：`Contents/Helpers/MoxWorker.app/Contents/MacOS/mox`。Core/Service 为 Xcode Debug 测试，UI 使用最终 Release App 与当前源码重新构建的 Debug MoxTestSupport；不能把规则测试说成 Release 真 MLX 测试。
- Apple Silicon 本机、macOS 27 / Xcode 27；macOS 15 未验证。

## 实际验证

| 验证 | 修改后结果 / 证据 |
| --- | --- |
| Core 全量 | 52 项通过；含 H2 的 2 个不确定提交分支与 6 个已索引任务/冲突组合。`.build/h12-core.log` |
| Service 全量 | 65 项通过；H1 参数化 FIN/RST 两分支。`.build/h12-service.log` |
| Release worker / App | 两次 BUILD SUCCEEDED，`.build/h12-release.log` |
| 官方 SDK / 真模型 / CLI / 重启 | PASS，`.build/h12-delivery-e2e.json`、`.build/h12-e2e.log`、`.build/h12-delivery-e2e.sdk.log` |
| GUI 最终 Release | 3 项通过：testFixtureLongReplyStopRetryAndHistory / testModelWorkspaceEntry / testM4APIControls。`.build/h12-ui.log`；停止/重试的两条取消结果、分支及 ≥1MiB 首回复重开保留 |
| 版本与差异 | stamp --check、git diff --check 最终核对通过 |

真实端到端在全新 `.build/h12-delivery-e2e`，从上轮隔离测试根 clone 已验证的 HF Qwen3 / MS Qwen2.5 产物，不是本轮重新下载的证据，也没有操作默认用户库。首次探活约 0.182 秒；记录 recovering→ready，但不推断超大库性能。验证 UUID alias/大写/实际 ID 的 CLI 真生成及冲突拒绝、两个官方 SDK 文本/流式/工具往返与错误矩阵、参数/pin 重启保留、托管模型按需生成、父控制 EOF 停止。另重开此前隔离 runtime 数据库，模型/参数/pin 保留；所有自有 worker 已停止。

复跑规则测试：

```sh
xcodebuild test -workspace .build/m4-package.xcworkspace -scheme MoxCoreTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
# 同参数将 scheme 改为 MoxServiceTests。
scripts/build-m4.sh Release
```

端到端复跑入口为 `scripts/verify-governance-boundaries.py`；传入最终 App、上述旧隔离测试根、一个**不存在的新** `.build` 直属 data-root、SDK Python 和 evidence 路径，可选 `--check-prior-store`。脚本限制隔离路径，并保留失败证据。不要覆盖本轮证据或使用默认用户根。

### 本轮失败与修正记录

- 首次编译遗漏参数转换的 `try`，以及新增 Core 测试遗漏分页 offset；修正后完整重跑通过。
- 测试误把终态当作 `/state.requests` 的元素，实际该数组只含活动请求；已按请求退出活动集合并查询保留终态验证。旧拒绝测试的 revision==0 与新登记生命周期冲突，改为拒绝后无活动请求且错误历史仍由聊天持久化保留。
- FIN 与 RST 不能共用“2 秒内连接复位”断言，固定 7 秒窗口也曾在复跑不足（`.build/h12-service-fin-window.log`）；HTTP 允许半关闭，参数化测试按现有 heartbeat + writeDeadline + 2 秒调度余量覆盖 FIN 写失败检测，RST 仍为 2 秒。终态必须 cancelled，记录后端身份排除迟到启动，同时保留单请求取消的 2 秒断言，未调大生产超时。另将已有放弃消费者测试固定睡 300ms 的竞态改为 2 秒内等待真实 lease 释放，不补发取消。
- Xcode 定向过滤曾实际选中 0 个 Swift Testing 测试，不计通过，最终运行完整 scheme。
- 日志含 Xcode 模拟器插件不匹配提示及既有临时 SwiftData 测试根删除时的 SQLite 警告；本轮 macOS 测试实际运行成功。它们不是用户库损坏证据；不据此声称已解决这些测试清理提示。

## 剩余限制与人工步骤

- 已交“严格评审 MLX 工程实现”会话做独立定向复核，结论待返回；原独立报告不改写为通过。人工验收仍未完成。
- 真实私有端点/凭据、macOS 15 真机受环境阻塞；超大模型库校验性能未测。可控 17 秒校验覆盖取消和超时逻辑，不替代真实大库性能测量。
- 本轮未重跑双源网络下载或完整 GUI 场景矩阵；历史证据见此前报告，不能计为新版本通过。
- 签名、公证、Homebrew、推送和发布不在本轮范围。

人工只需补体验确认，不承担 H1/H2 自动化正确性兜底：

1. 最终 App 重开服务后，在托管模型仍校验时发送消息并停止，确认停止提示、窗口响应和随后再次生成的体验。
2. 查看模型/下载列表及已有测试历史，重开后显示一致；退出自有服务与外部服务的提示/所有权体验按既有 M2/M3/M4 清单验收。

下一步：独立会话只核验 H1/H2 与上述状态组合，不重新展开已关闭架构治理。
