# Mox

面向 Apple Silicon macOS 的原生 MLX 模型管理与运行工具。

## 当前状态

工程正在按已确认的新架构重写。当前仅包含 Swift 6 基础包，尚不提供可用 CLI、GUI 或推理服务。旧实现已保存在 Git 提交 `845470a`，不参与新工程构建。

## 已确认的方向

- 独立 macOS App；Homebrew 为可选分发与服务托管方式。
- 官方 MLX 推理；Hugging Face、ModelScope 和同协议自定义来源。
- SwiftUI GUI、SwiftData 持久化、CLI 与 HTTP 接口。
- 首版文本对话与工具调用；后续多模态和可选 agent 集成。
- 无管理员运行需求；明确区分 App 启动与外部托管服务的所有权。

## 开发

需要 Apple Silicon Mac、完整 Xcode 和 Swift 6.2 或更新工具链。

```sh
swift build
```

当前依赖方向为 `MoxCore → MoxDomain`。外部适配模块与 App target 随第一条真实功能链路加入，当前没有第三方依赖。MoxCore 暂不承诺稳定 SDK/ABI。

## 设计依据

[0.1 发布计划](docs/RELEASE-PLAN.md) · [M1 可执行规格](docs/milestones/M1.md)

**新会话续接先读 [HANDOFF](docs/HANDOFF.md)**，其中记录当前状态、阅读顺序和下一步。

开发、自测和人工验收统一遵循 [CONTRIBUTING](CONTRIBUTING.md)。

- [产品与行为契约](ARCHITECTURE-DRAFT.md)
- [技术方案](docs/architecture/TECHNICAL-DESIGN.md)
- [竞品与选型补充](docs/architecture/COMPETITOR-AND-SELECTION-REVIEW.md)
- [执行记录](docs/architecture/REWRITE-EXECUTION.md)

许可证见 [LICENSE](LICENSE)。
