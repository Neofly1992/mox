# M1 依赖与资源

核验日期：2026-09-06。根目录 `Package.resolved` 锁定完整传递依赖版本及 revision。

| 直接依赖 | 固定版本 | 许可证 | 职责 |
| --- | --- | --- | --- |
| ml-explore/mlx-swift | 0.31.6 | MIT | Apple Silicon GPU 数组、Metal、内存统计 |
| ml-explore/mlx-swift-lm | 3.31.4 | MIT | 官方模型 factory、processor、生成和统计 |
| huggingface/swift-transformers | 1.3.3 | Apache-2.0 | 本地 tokenizer 与 chat template |
| apple/swift-argument-parser | 1.8.2 | Apache-2.0 | CLI 参数、帮助及类型检查 |

使用稳定 tag，不跟随 main。MLX 的最低编译工具链为 Swift 6.3；Mox 部署目标仍为 macOS 15。编译需要完整 Xcode 及 Apple Metal Toolchain，产物运行不需要 Python、brew 或单独安装 CLI 依赖。这里的 Python 脚本仅是开发验收工具。

MLX 的同步生成回调已标 deprecated，选择依据和缓冲核验见技术设计 §13；依赖升级需要复测，不应自动换回无界流。所有模型计算都使用官方实现。

`build-m1.sh` 携带官方 Metal/SwiftPM bundles，并从锁定 checkouts 收集 LICENSE/NOTICE 到本地产物的 licenses 目录。完整依赖自己的源码/嵌套第三方许可证仍随 checkouts 可查；本阶段不是公开分发许可清单或签名公证验收。

测试模型是 `mlx-community/Qwen2.5-0.5B-Instruct-4bit`，revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，权重大小 278064920 字节，LFS SHA256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153`。模型文件不提交到 Git。测试目录 `.build/test-models/qwen2.5-0.5b-4bit` 可由使用者明确清理；Mox 自身只读引用该目录。
