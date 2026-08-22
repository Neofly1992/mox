# Mox

**Magic Box for MLX** — Apple-Silicon-only 大模型运行工具。

[![Swift](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-333333.svg)](https://developer.apple.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 当前状态（v0.6 / 2026-08）

| 能力 | 状态 |
| --- | --- |
| `mox pull / list / delete / run / chat / -m / ask` | ✅ |
| `mox-server daemon / install / start / stop / status / logs` | ✅ |
| `mox-server` 通过 launchd 注册为 user LaunchAgent | ✅ |
| Apple-Silicon `daemon.enabled` 模式 + 临时模式双形态 | ✅ |
| OpenAI `/v1/chat/completions`（非流式 JSON） | ✅ |
| Anthropic `/v1/messages`（含 SSE 流） | ✅ |
| mlx-swift-lm 集成（58 个 model_type） | ✅ |
| 下载：HTTP Range + SHA-256 + 路径穿越防御 + 镜像白名单 | ✅ |
| SwiftUI GUI（MoxGUI）— Settings / Models / Logs tab + 菜单栏 | ✅ |
| MoxConvertCore：智能 pull routing + manifest inspect | ✅ |

未交付：

- OpenAI `/v1/chat/completions` SSE 流式（仅 Anthropic SSE）
- bf16 → MLX 自动转换（等上游 `MLX.nn.Module → safetensors` API）
- `mox convert` / `mox re-quantize` CLI（无 backend）
- 真机 M芯片 Mac 端到端 smoke（用户手动）

## 快速开始

### 在 Apple Silicon Mac 上构建

```bash
cd mox
swift build
swift run mox --help
swift run mox-server help
```

### 命令行

```bash
# 下载模型
mox pull Qwen/Qwen2.5-0.5B-Instruct
mox pull Qwen/Qwen2.5-0.5B-Instruct --source modelscope

# 查看本地模型
mox list

# 交互式聊天（REPL）
mox chat Qwen/Qwen2.5-0.5B-Instruct
# /exit /clear /help

# 单次对话（OpenAI 兼容 JSON 输出）
mox ask --model Qwen/Qwen2.5-0.5B-Instruct --messages '[{"role":"user","content":"hi"}]'
mox ask --model Qwen/Qwen2.5-0.5B-Instruct --messages '[…]' --stream

# 启动后台 server（默认端口 11555）
mox run Qwen/Qwen2.5-0.5B-Instruct --port 11555

# 注册为 launchd 常驻 daemon（Mac 启动自动启动）
mox-server install
mox-server start          # 立即拉起
mox-server status         # exit 0=running / 3=loaded-not-running / 4=not-loaded
mox-server stop
mox-server uninstall
mox-server logs --lines 200
mox-server logs --stderr  # 分流的 stderr

# 删除模型
mox delete Qwen/Qwen2.5-0.5B-Instruct
```

### HTTP API

`mox run` 或 launchd daemon 同时支持 OpenAI / Anthropic 协议：

| 端点 | 方法 | 协议 |
| --- | --- | --- |
| `/health` | GET | 通用 |
| `/v1/models` | GET | OpenAI |
| `/v1/chat/completions` | POST | OpenAI（非流式 JSON；SSE 暂未） |
| `/v1/messages` | POST | Anthropic Messages（流 + 工具 400 拒绝） |

```bash
# OpenAI
curl http://localhost:11555/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model":"Qwen/Qwen2.5-0.5B-Instruct",
    "messages":[{"role":"user","content":"Hello!"}]
  }'

# Anthropic（流式）
curl -N http://localhost:11555/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{
    "model":"Qwen/Qwen2.5-0.5B-Instruct",
    "max_tokens":128,
    "messages":[{"role":"user","content":"hi"}]
  }'
```

## 项目结构

```
Sources/
├── MoxShared/             # 跨模块类型（Sendable + Codable）
├── MoxCore/               # 配置、下载、内存、模型管理、MLX 推理
├── MoxServer/             # NIO HTTP server（OpenAI + Anthropic）
├── MoxServerCLI/          # mox-server 二进制 + launchd agent
├── MoxConvertCore/        # v0.5 智能 pull routing（HF config probe）
├── MoxCLI/                # mox 二进制
├── MoxGUI/                # MoxGUI SwiftUI 可执行
├── MoxGUIClient/          # GUI 协议 client（不依赖 MoxCore）
└── Tests/
    ├── MoxCoreTests/      # ConfigManager / Downloader / Anthropic / 路由
    └── MoxGUIClientTests/ # 启动决策 + ProcessAPIClient fixtures
```

详细目标/产品/依赖矩阵见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 构建与测试

```bash
swift build                       # debug
swift build -c release            # release
swift test                        # 52 测试
swift run mox --help
swift run mox-server help
```

测试用 [swift-testing](https://github.com/swiftlang/swift-testing) —`XCTest` 在 CommandLineTools SDK 下不可用。

## 数据目录

```
~/.mox/
├── config.json     # 用户配置（AppConfig + daemon.enabled）
└── models/         # 模型文件
    └── Qwen-Qwen2.5-0.5B-Instruct/
        ├── config.json
        ├── model.safetensors
        └── mox.json     # ModelManifest（v0.5 inspect 写入）
```

## 配置

`~/.mox/config.json`：

```json
{
  "version": 1,
  "defaultSource": "huggingface",
  "mirrors": {
    "huggingface": "",
    "modelscope": ""
  },
  "server": {
    "host": "127.0.0.1",
    "port": 11555
  },
  "defaults": {
    "maxTokens": 2048,
    "temperature": 0.7,
    "topP": 0.9
  },
  "memory": {
    "reservePercent": 0.1
  },
  "daemon": {
    "enabled": false
  }
}
```

`daemon.enabled`：`true` 期望 launchd daemon（不在则 GUI 弹 dialog）、`false` 临时模式、缺字段等同 `false`。`mox-server install` 写 `true`，`mox-server uninstall` 写 `false`。

## 依赖

| Package | 用途 |
| --- | --- |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | Apple MLX 框架 |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | LLM/VLM 推理，58 个 model_type |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | `HubClient` + tokenizer loader |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Hub + Tokenizers |
| [swift-nio](https://github.com/apple/swift-nio) | Server / CLI 异步网络 |
| [swift-testing](https://github.com/swiftlang/swift-testing) | 测试框架（CommandLineTools SDK 残缺） |

无第三方下载库，使用原生 `URLSession` + HTTP Range + SHA-256。

## License

MIT