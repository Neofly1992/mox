# Mox

面向 Apple Silicon macOS 的原生 MLX 模型管理与运行工具。

## 当前状态

工程正在按已确认的新架构重写。M1 已实现本地 MLX 文本模型的只读加载、流式生成、取消等待与交互 CLI；当前待人工验收，操作与证据见 [M1 验收报告](docs/acceptance/M1.md)。GUI、HTTP 和模型下载属于后续阶段。旧实现只保留在 Git 历史，不参与构建。

## 已确认的方向

- 独立 macOS App；Homebrew 为可选分发与服务托管方式。
- 官方 MLX 推理；Hugging Face、ModelScope 和同协议自定义来源。
- SwiftUI GUI、SwiftData 持久化、CLI 与 HTTP 接口。
- 首版文本对话与工具调用；后续多模态和可选 agent 集成。
- 无管理员运行需求；明确区分 App 启动与外部托管服务的所有权。

## 开发

需要 Apple Silicon Mac、完整 Xcode、Swift 6.3 和 Xcode 的 Metal Toolchain 组件。部署目标 macOS 15，当前真机验证为 macOS 26.6.2。

```sh
scripts/build-m1.sh
swift test
```

产物为 `.build/m1/mox`，必须保留同目录的 `mlx.metallib` 和 bundles。`swift build` 只编译 Swift/C++，不能独立生成 Metal 资源。首次缺少 Metal 编译器时运行 `xcodebuild -downloadComponent MetalToolchain`。

```sh
.build/m1/mox chat --model-path /absolute/path/to/local-model --prompt '你好' --max-tokens 64
.build/m1/mox chat --model-path /absolute/path/to/local-model
```

省略 prompt 进入交互会话。Ctrl-C 停止当前生成并等待回到输入；空闲 Ctrl-C 或 EOF 退出。stdout 为回复，stderr 为阶段和诊断。输入超限明确拒绝，不截断历史；取消/失败的问答不加入下一轮。

真实测试（已有本地模型，不自动下载）：

```sh
MOX_TEST_MODEL=/absolute/path/to/local-model scripts/test-m1-real.sh
python3 scripts/test-m1-cli.py --binary .build/m1/mox --model /absolute/path/to/local-model
```

依赖方向 `MoxCLI → MoxMLX → MoxCore → MoxDomain`；CLI 不重复推理业务。固定版本、许可证与测试模型身份见 [依赖说明](docs/DEPENDENCIES.md)。MoxCore 暂不承诺稳定 SDK/ABI。

## 设计依据

[0.1 发布计划](docs/RELEASE-PLAN.md) · [M1 可执行规格](docs/milestones/M1.md)

**新会话续接先读 [HANDOFF](docs/HANDOFF.md)**，其中记录当前状态、阅读顺序和下一步。

开发、自测和人工验收统一遵循 [CONTRIBUTING](CONTRIBUTING.md)。

- [产品与行为契约](ARCHITECTURE-DRAFT.md)
- [技术方案](docs/architecture/TECHNICAL-DESIGN.md)
- [竞品与选型补充](docs/architecture/COMPETITOR-AND-SELECTION-REVIEW.md)
- [执行记录](docs/architecture/REWRITE-EXECUTION.md)

许可证见 [LICENSE](LICENSE)。
