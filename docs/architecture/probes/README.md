# SwiftData 无界面验证

2026-09-06：完整 Xcode 26.6 下已通过编译、独立进程保存和重开断言，证据位于 `/tmp/mox-swiftdata-probe.6aP3gK`。执行环境需允许 Apple 宏插件启动；Codex 沙箱内曾报 `sandbox_apply: Operation not permitted`，经沙箱外运行通过。下文 Command Line Tools 失败记录为早期历史状态。

推荐运行 `bash docs/architecture/probes/run-swiftdata.sh`。脚本检查完整 Xcode，独立编译，然后断言两个进程的输出；环境缺失退出 2，不能记作测试通过。可通过 `DEVELOPER_DIR` 指定 Xcode。

目的：确认正式工具链下，独立 Swift 进程可通过 ModelActor 写入 SwiftData，并由随后启动的进程重新读取。不是完整事务、迁移或并发测试。

本轮环境 active developer directory 为 Command Line Tools；编译报缺失 SwiftDataMacros plugin，未运行到保存和读取。不要把该结果记作运行测试通过，也不要因此替换 SwiftData。

完整 Xcode 就绪后，从仓库根目录运行（按实际安装位置调整 DEVELOPER_DIR；使用环境覆盖，不修改全局 xcode-select）：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
probe_dir=$(mktemp -d /tmp/mox-swiftdata-probe.XXXXXX)
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$probe_dir/cache" \
  docs/architecture/probes/SwiftDataProbe.swift \
  -o "$probe_dir/store-probe"
"$probe_dir/store-probe" write "$probe_dir/probe.store"
"$probe_dir/store-probe" read "$probe_dir/probe.store"
```

预期两个进程均输出 `["interrupted"]`，且退出 0。该验证不访问用户数据、不需要网络、不使用工程 `.build`。首次编译失败时应先修复环境/代码，不继续执行后续不存在的二进制。

之后 G0/G1 仍需测试明确保存、取消时终态、进程异常恢复和正式 schema 的操作；此 probe 不能替代它们。
