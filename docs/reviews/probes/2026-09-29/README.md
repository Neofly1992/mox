# 全仓审查故障探针

被测基线 `c6b7b5d`。`ReviewCoreTests.swift` 是审查用回归测试，基线上两项都应失败；不是生产功能实现。复用仓库的 `fixture`、`ProbeBackend`、`runtime` 测试设施。下载探针通过暂停 persistence，在另一配置写入期间完成文件下载，复现进度及错误终态保存均被 busy 拒绝；不主动取消下载来制造失败。

可将此文件临时加入 `Tests/MoxCoreTests` 后用 Core 测试 scheme 运行，注意不覆盖已有文件。2026-09-29 实际采用隔离包，避免本机默认 SwiftPM 构建的 Metal 组件问题：原样复制 `Sources/MoxDomain`、`Sources/MoxCore`、`Tests/MoxCoreTests` 到临时 Swift package，再加入本文件；包使用 Swift 6，macOS 15，Core 依赖 Domain，CoreTests 依赖 Core。运行：

```sh
swift test --package-path .build/review-20260929/core --build-system native --filter review
```

`.build/review-20260929/core` 是本轮辅助产物，清理后应按以上说明重建，不是仓库构建入口。完整执行结果及环境限制见上层审查报告。修复时应将必要测试正式纳入项目测试目标，不长期维护一份与正式测试重复的测试副本。
