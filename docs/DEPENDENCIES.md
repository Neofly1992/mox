# 依赖与资源

[Package.resolved](../Package.resolved) 锁定完整传递依赖版本和 revision，构建不跟随 main。本次仓库整理未升级依赖。

| 直接依赖 | 版本 | 许可证 | 职责 |
| --- | --- | --- | --- |
| hummingbird-project/hummingbird | 2.26.0 | Apache-2.0 | HTTP、NIO 背压 |
| ml-explore/mlx-swift | 0.31.6 | MIT | Apple Silicon GPU、Metal、内存统计 |
| ml-explore/mlx-swift-lm | 3.31.4 | MIT | 官方模型加载与生成 |
| huggingface/swift-transformers | 1.3.3 | Apache-2.0 | tokenizer、chat template |
| apple/swift-argument-parser | 1.8.2 | Apache-2.0 | CLI 参数与帮助 |
| huggingface/swift-huggingface | 0.11.0 | Apache-2.0 | Hugging Face 元数据和受控鉴权 |

需要 Swift 6.3 或更新、完整 Xcode 与 Metal Toolchain。App 使用系统 SwiftUI、AppKit、SwiftData 和 URLSession，不链接 Server/MLX；嵌套 worker 携带官方 Metal/SwiftPM bundles。部署目标 macOS 15 尚未真机验证。

同步生成回调的使用理由见[架构](ARCHITECTURE.md)，升级依赖必须重新验证流控和取消。ModelScope 薄适配参考官方 modelscope_hub HTTP 约定，不携带 Python 运行时。

构建入口 [build.sh](../scripts/build.sh) 从锁定 checkouts 递归收集 LICENSE/NOTICE/COPYING 到产物 licenses 目录。完整清单见[第三方声明](../THIRD_PARTY.md)。不要删除嵌套第三方声明；模型许可证不由 Mox 的 MIT License 覆盖。

真实验证夹具：`mlx-community/Qwen2.5-0.5B-Instruct-4bit`，revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，权重 278064920 字节，LFS SHA256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153`。权重不入 Git；准备与运行方法见[开发说明](DEVELOPMENT.md)。
