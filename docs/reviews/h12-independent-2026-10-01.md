# H1/H2 独立定向复核（2026-10-01）

## 结论

**H1、H2 可关闭。本次限定范围内未发现新的必需修复项，可进入用户体验验收；不代填首版人工验收或发布放行。** 不重新展开已认可的 A1/A2/F1–F3/G2。

基线：`codex/rewrite` / `c6b7b5d` 加已有未提交工作树。生产指纹独立核对为 `mox-m4-20e5bda64de91964ed3bedf44a7905ed171fac01f189e74d0a8542cb8d5c01a8`。未修改生产代码、正式测试或用户数据，未提交、推送或发布。

## H1：请求准备、取消与共享校验

检查 `Service.begin/response`、`ModelLibraryService.startGeneration/executePlan`、`GenerationHandle`、`DownloadManager.verifyInstallation`、`SharedVerificationWait` 及对应测试。请求在校验前登记；输出句柄拥有准备到后端停止的生命周期；私有连接关闭处理在开始准备前绑定。元数据拒绝仍走 HTTP 错误出口，耗时校验通过句柄事件报告。取消等待者不取消库拥有的共享校验；等待注册、完成和取消通过锁协调，校验后再次检查取消，后端句柄也绑定外层取消。

独立重跑正式 `PreparationCancellationTests` 的 FIN/RST 两分支：17 秒校验期间状态可见；单请求取消在 2 秒窗口内结束；共享等待者继续完成且 verifier 仅一次；取消及断连的 requestID 未进入后端；再次生成成功。该测试包含真实本机 HTTP/socket，后端与慢校验器为测试替身，不是 MLX 性能证据。

实际 RST 终止约 0.015543 秒，FIN 约 5.009465 秒。核对实现者此前固定 7 秒窗口失败记录，未将其隐藏或算作通过。当前 FIN 断言取既有 heartbeat（5 秒）+ writeDeadline（5 秒）+ 2 秒调度余量，单请求取消/RST 仍为 2 秒；生产期限未增大。FIN 的传输写失败检测不同于显式取消，当前有界断言可接受，不承诺 FIN 必定瞬时停止。

## H2：已有索引与任务终态补全

检查 `DownloadManager.recover/recoverCommitted` 与持久层分页排序。启动恢复对已有索引的未完成任务重新核对实际 manifest，复用幂等补全；不是仅凭目录或索引存在宣布 installed。补全保留现有安装身份/别名/pin/采样参数，清除错误并补齐字节数。按身份更新不改变分页排序键。

独立重跑 `RestartCompletionTests`：索引提交前失败、保存后抛错均在重开后完成；已有索引与 committing/interrupted/failed 三状态分别覆盖匹配/冲突，共六组合；匹配补全并再次重开幂等，冲突不宣布 installed。原损坏/冲突产物与下载生命周期回归亦通过。这里的提交失败是可控 persistence 故障注入，不伪称系统真实断电实验。

## 本轮独立运行证据

- Xcode Core：52 项通过，`.build/review-h12/core.log`。
- Xcode Service：65 项通过，`.build/review-h12/service.log`；实际执行 Swift Testing，非过滤后 0 项。
- `MOX_BUILD_MILESTONE=m4 python3 scripts/stamp-m3-build.py --check` 与 `git diff --check` 通过。
- 规则测试命令：`xcodebuild test -workspace .build/m4-package.xcworkspace -scheme MoxCoreTests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO`；Service 替换 scheme 为 `MoxServiceTests`。首次沙箱内 Xcode 无法访问 workspace/构建服务，未运行测试；获准在沙箱外重跑成功。日志含既有 Xcode 插件及临时 SwiftData 清理提示，不作为产品数据损坏结论。

本轮是源码审查和当前测试的独立执行，没有新添生产逻辑或测试副本。Release 构建、GUI 3 项、两官方 SDK、真实模型/CLI/重启属于[实现者本轮证据](../acceptance/source-release-h12-2026-10-01.md)，本会话未重复执行，不计入独立运行。真实双源网络下载、完整 GUI 矩阵、macOS 15、私有端点、超大库耗时也未在本轮验证。

下一步由用户完成实现者报告中的体验场景和仍待验收的 M2/M3/M4 相关体验；出现具体反馈再修复关联路径。没有发现需要继续展开架构治理的依据。人工结果记录后，再按用户授权决定源码发布；签名、公证和 Homebrew 不属于本轮。
