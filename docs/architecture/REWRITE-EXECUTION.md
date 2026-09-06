# 重写执行记录

用户已确认按新架构重写，保留 Git 历史，不为原实现建立兼容层。

## 切换前检查（2026-09-05）

- 工作区已有 Package.swift、Server.swift、HTTPRouter.swift 修改及未跟踪测试，不覆盖这些尚未协调的开发成果。
- 源码、测试、设计文档快照：`/tmp/mox-before-rewrite-20260905/source-and-design.tar.gz`；已跟踪修改补丁：同目录 `working-tree.patch`。这是临时保险副本，不替代 Git 的长期归档。
- 当前 active developer directory 为 `/Library/Developer/CommandLineTools`，默认 Applications 中未发现 Xcode。
- 第一阶段为 G0 风险验证，不先创建大量空 target。SwiftData 跨进程保存/重开已有自动断言脚本；需完整 Xcode 后执行。

## 后续顺序

2026-09-06 更新：Xcode 26.6 (17F113) 可正常运行，`xcodebuild -checkFirstLaunchStatus` 退出 0。SwiftData probe 在沙箱外编译执行通过，明确保存及新进程重开均符合断言，证据目录 `/tmp/mox-swiftdata-probe.6aP3gK`。首次沙箱内运行被 sandbox_apply 拒绝导致宏插件失败，不是 Xcode 安装缺失。G0 的 Metal 资源及 App 验证仍待完成。

1. 完整 Xcode 完成首次启动，通过 SwiftData probe；验证 Metal 资源打包。环境问题不能算产品测试失败或通过。
2. 协调停止旧实现写入，将当前状态归档后切换正式 Sources/Package；不长期保留两个工程。
3. 先实现 Domain/Core 的模型身份、安装与运行状态契约，再接入 SwiftData 和官方 MLX，完成本地模型生成、取消并等待、再次生成的真实闭环。
4. 引入 Hummingbird 与 Client/Bootstrap，验证三种服务所有权及流式协议；随后下载、GUI 和对外 agent 协议。

验收以 TECHNICAL-DESIGN 的 G0–G7 和 COMPETITOR-AND-SELECTION-REVIEW 的能力矩阵为准。当前未宣称新实现或 G0 已完成。

## 2026-09-06 工程切换已完成

- 重写前完整快照提交：`845470a`，含未提交源码、测试和设计。因原环境没有 Git 身份，沿用既有提交的 `neo <neo@local>`，仅对该命令生效。
- 当前分支：`codex/rewrite`。分支在快照提交前已创建，因此快照在此分支历史中；原分支没有被移动。
- 删除旧 Sources/Tests、旧 GUI smoke 脚本、依赖锁定文件及过期 DESIGN/ROADMAP/CHANGELOG/CONTRIBUTING；旧内容可从快照查看。
- 新 SwiftPM 包仅建立 Domain/Core 边界，Swift 6、macOS 15，无第三方依赖；其余模块随功能加入。当前没有 CLI/GUI 或推理实现。
- 独立 scratch path 构建通过；`git diff --check` 通过。未搬运旧测试，当前不宣称功能测试通过。
- 上文环境阻塞和待切换条目为过程记录，已被本条及 Xcode 验证结果更新。
