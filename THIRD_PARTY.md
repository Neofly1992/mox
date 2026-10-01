# 第三方声明

Mox 自身使用 [MIT License](LICENSE)，Copyright 2026 Neo。下面的依赖使用独立许可证；固定版本与 revision 的权威来源是 [Package.resolved](Package.resolved)。本次整理没有升级依赖。

## Swift 依赖

| 依赖 | 锁定版本 | 许可证 |
| --- | --- | --- |
| [async-http-client](https://github.com/swift-server/async-http-client.git) | 1.36.1 | Apache-2.0 |
| [eventsource](https://github.com/mattt/EventSource.git) | 1.4.2 | MIT |
| [hummingbird](https://github.com/hummingbird-project/hummingbird) | 2.26.0 | Apache-2.0 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift.git) | 0.31.6 | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm.git) | 3.31.4 | MIT |
| [swift-algorithms](https://github.com/apple/swift-algorithms.git) | 1.2.1 | Apache-2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1.git) | 1.7.1 | Apache-2.0 |
| [swift-async-algorithms](https://github.com/apple/swift-async-algorithms.git) | 1.1.3 | Apache-2.0 |
| [swift-atomics](https://github.com/apple/swift-atomics.git) | 1.3.0 | Apache-2.0 |
| [swift-certificates](https://github.com/apple/swift-certificates.git) | 1.20.0 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections.git) | 1.4.1 | Apache-2.0 |
| [swift-configuration](https://github.com/apple/swift-configuration.git) | 1.2.0 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto.git) | 4.5.1 | Apache-2.0 |
| [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing.git) | 1.4.1 | Apache-2.0 |
| [swift-http-structured-headers](https://github.com/apple/swift-http-structured-headers.git) | 1.7.0 | Apache-2.0 |
| [swift-http-types](https://github.com/apple/swift-http-types.git) | 1.8.0 | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | 0.11.0 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja.git) | 2.4.2 | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log.git) | 1.15.1 | Apache-2.0 |
| [swift-metrics](https://github.com/apple/swift-metrics.git) | 2.11.0 | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio.git) | 2.101.3 | Apache-2.0 |
| [swift-nio-extras](https://github.com/apple/swift-nio-extras.git) | 1.35.1 | Apache-2.0 |
| [swift-nio-http2](https://github.com/apple/swift-nio-http2.git) | 1.46.0 | Apache-2.0 |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl.git) | 2.37.4 | Apache-2.0 |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services.git) | 1.28.0 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [swift-service-context](https://github.com/apple/swift-service-context.git) | 1.3.0 | Apache-2.0 |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle.git) | 2.12.0 | Apache-2.0 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax.git) | 603.0.2 | Apache-2.0 |
| [swift-system](https://github.com/apple/swift-system.git) | 1.8.1 | Apache-2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.3.3 | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson.git) | 0.12.0 | MIT |

## 嵌套第三方资源

MLX Swift 的 Cmlx 源码还包含 Apple metal-cpp（Apache-2.0）、fmt（MIT）、MLX / mlx-c（MIT）及 nlohmann/json（MIT）的声明；fmt 文档工具还包含 Python 许可证。构建脚本递归保留锁定依赖中的 LICENSE、NOTICE、COPYING 文件及相对路径，不仅复制顶层 LICENSE。许可证实际文本随源码 checkout 及本地产物 `licenses` 目录可查。

App 内嵌 worker 的 Resources 含许可证与官方 SwiftPM/Metal bundles。模型不入仓库，下载或引用模型前应检查对应模型卡和许可证。Mox 的许可证不授权重新分发第三方模型。

OpenAI / Anthropic Python SDK 仅用于开发端到端验收，不嵌入 App。Apple 系统框架和开发工具由其自身条款覆盖。本页是源码仓库的依赖声明，不代表已完成签名、公证或二进制分发许可验收。
