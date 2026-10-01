# 首版源码依赖与资源

首次核验：2026-09-06；源码发布收口：2026-09-29。根目录 `Package.resolved` 锁定完整传递依赖版本及 revision。当前构建入口为 `scripts/build-m4.sh [Debug|Release]`；准确构建证据见[收口报告](acceptance/source-release-2026-09-29.md)。

| 直接依赖 | 固定版本 | 许可证 | 职责 |
| --- | --- | --- | --- |
| hummingbird-project/hummingbird | 2.26.0 | Apache-2.0 | M2 私有 loopback HTTP listener / NIO 背压 |
| ml-explore/mlx-swift | 0.31.6 | MIT | Apple Silicon GPU 数组、Metal、内存统计 |
| ml-explore/mlx-swift-lm | 3.31.4 | MIT | 官方模型 factory、processor、生成和统计 |
| huggingface/swift-transformers | 1.3.3 | Apache-2.0 | 本地 tokenizer 与 chat template |
| apple/swift-argument-parser | 1.8.2 | Apache-2.0 | CLI 参数、帮助及类型检查 |
| huggingface/swift-huggingface | 0.11.0 | Apache-2.0 | HF 元数据、树分页与受控鉴权 |

使用稳定 tag，不跟随 main。MLX 的最低编译工具链为 Swift 6.3；Mox 部署目标仍为 macOS 15。编译需要完整 Xcode 及 Apple Metal Toolchain，产物运行不需要 Python、brew 或单独安装 CLI 依赖。这里的 Python 脚本仅是开发验收工具。

MLX 的同步生成回调已标 deprecated，选择依据和缓冲核验见技术设计 §13；依赖升级需要复测，不应自动换回无界流。所有模型计算都使用官方实现。

当前构建脚本携带官方 Metal/SwiftPM bundles，并从锁定 checkouts 收集 LICENSE/NOTICE 到本地产物的 licenses 目录。完整依赖自己的源码/嵌套第三方许可证仍随 checkouts 可查；签名、公证与二进制分发许可核查属于 P1。

测试模型是 `mlx-community/Qwen2.5-0.5B-Instruct-4bit`，revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，权重大小 278064920 字节，LFS SHA256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153`。模型文件不提交到 Git。测试目录 `.build/test-models/qwen2.5-0.5b-4bit` 可由使用者明确清理；Mox 自身只读引用该目录。

M2 在 2026-09-08 核验 Hummingbird 2.26.0 稳定 tag 及实际源码 API，固定版本已写入 Package.swift/Package.resolved。App 使用系统 SwiftUI/AppKit/SwiftData，客户端使用 URLSession，不把 Server/MLX 链接进 GUI。当前脚本产出 `.build/m4/{Debug,Release}/Mox.app`，worker 位于 `Contents/Helpers/MoxWorker.app/Contents/MacOS/mox`，官方 bundles 和许可证位于嵌套 worker 的 Resources。构建成功不代表用户验收完成。

M3 已实现并在首版源码收口中复核：新增官方 [swift-huggingface 0.11.0](https://github.com/huggingface/swift-huggingface/releases/tag/0.11.0)（Apache-2.0），锁定于 Package.resolved。实际核验 getModel、tree 分页、受控 host/token provider；Mox 自己负责下载任务、完整性和安装事务。下载字节用原生 URLSession 且限制凭据跨 origin；不在构建成功前声称完成该组合的端到端测试。ModelScope 参考官方 [modelscope_hub](https://github.com/modelscope/modelscope_hub) commit `0b2a3bacef4cbeccfd9a64545149d56cb1bb98a1` 的 HTTP 约定，Swift 薄适配不携带 Python 运行时。
