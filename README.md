# Mox

**Magic Box for MLX** — 为 Apple Silicon 提供的本地大模型运行工具。

[![Swift Version](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-333333.svg)](https://developer.apple.com/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 功能状态

### ✅ 已完成 (v0.1.0-Alpha)

| 命令 | 功能 | 状态 |
|------|------|------|
| `mox pull <model>` | 从 HuggingFace 下载模型 | ✅ |
| `mox pull <model> --source modelscope` | 从 ModelScope 下载模型 | ✅ |
| `mox list` | 列出本地模型 | ✅ |
| `mox run <model>` | 启动 API 服务器 | ✅ |
| `mox chat <model>` | 交互式聊天 | ✅ |
| `mox -m "prompt"` | 单次对话 | ✅ |
| `mox delete <model>` | 删除模型 | ✅ |
| 内存检查 | 加载前检查内存 | ✅ |
| 断点续传 | HTTP Range 支持 | ✅ |

### 🔧 待完成

- [ ] 模型推理（MLX Swift API 集成）
- [ ] 下载进度显示优化
- [ ] 流式输出
- [ ] 模型搜索
- [ ] SwiftUI GUI

## 快速开始

### 在 M 芯片 Mac 上构建

```bash
cd mox
swift build
swift run mox --help
```

### 命令行使用

```bash
# 查看帮助
mox --help

# 下载模型
mox pull Qwen/Qwen2.5-0.5B-Instruct
mox pull Qwen/Qwen2.5-0.5B-Instruct --source modelscope

# 查看本地模型
mox list

# 交互式聊天
mox chat Qwen/Qwen2.5-0.5B-Instruct

# 单次对话
mox -m "What is 2+2?"

# 启动 API 服务器
mox run Qwen/Qwen2.5-0.5B-Instruct --port 8080

# 删除模型
mox delete Qwen/Qwen2.5-0.5B-Instruct
```

## 项目结构

```
Sources/
├── MoxShared/
│   └── Models.swift          # 共享类型 (ModelInfo, AppConfig, ChatMessage, etc.)
├── MoxCore/
│   ├── ConfigManager.swift   # 配置管理 (JSON)
│   ├── Downloader.swift      # 断点续传下载器
│   ├── MemoryGuard.swift    # 内存检查
│   ├── ModelManager.swift    # 模型生命周期管理
│   └── ModelRunner.swift     # 模型加载 (TODO: 集成 MLX)
├── MoxServer/
│   └── Server.swift          # HTTP API 服务器 (OpenAI 兼容)
└── MoxCLI/
    └── main.swift            # CLI 入口
```

## 架构设计

```
┌─────────────────────────────────────────────────────┐
│                       Mox                              │
├─────────────────────────────────────────────────────┤
│  CLI Interface (MoxCLI)                             │
│  ├── pull, list, delete                            │
│  ├── run (启动服务器)                               │
│  └── chat / -m (单次对话)                           │
├─────────────────────────────────────────────────────┤
│  HTTP Server (MoxServer)                           │
│  ├── OpenAI Compatible REST API                     │
│  └── /v1/chat/completions, /v1/models, /health      │
├─────────────────────────────────────────────────────┤
│  Core (MoxCore)                                    │
│  ├── ModelManager     # 下载/删除/列表               │
│  ├── ModelRunner     # 加载/推理 (TODO)            │
│  ├── Downloader      # 断点续传                    │
│  ├── MemoryGuard     # 内存检查                     │
│  └── ConfigManager   # 配置                         │
└─────────────────────────────────────────────────────┘
```

## 继续开发指南

### 1. 集成 MLX 推理

**文件**: `Sources/MoxCore/ModelRunner.swift`

当前是 placeholder，需要集成 MLX Swift：

```swift
// 当前代码 (placeholder)
public func chat(modelId: String, messages: [ChatMessage], ...) async throws -> ChatCompletionResponse {
    // TODO: 使用 MLX Swift 生成响应
    return ChatCompletionResponse(...)
}
```

参考: [mlx-swift](https://github.com/ml-explore/mlx-swift)

### 2. 配置格式

当前使用 JSON (`~/.mox/config.json`)。如需改用 TOML，需要：
- 添加 TOML 解析库依赖 (如 `toml-swift`)
- 或使用 swift-nio 的 `NIOTOML`

### 3. ModelScope API

已实现基础下载。如需完善，检查 ModelScope API 文档：
- 获取文件列表: `GET /api/v1/models/{namespace}/{name}`
- 下载文件: `GET /api/v1/models/{namespace}/{name}/raw?FilePath={path}`

### 4. GUI 准备

架构已考虑 GUI 扩展：
- `MoxCore` 无 UI 依赖，可被任何层调用
- `MoxShared` 提供所有数据类型
- 考虑添加 `MoxGUI` target (SwiftUI)

## 构建与测试

```bash
# 构建
swift build

# 发布构建
swift build -c release

# 运行
swift run mox --help

# 测试
swift test
```

## 数据目录

```
~/.mox/
├── config.json     # 用户配置
└── models/        # 模型文件
    └── Qwen-Qwen2.5-0.5B-Instruct/
        ├── config.json
        ├── model.safetensors
        └── ...
```

## 配置示例

`~/.mox/config.json`:

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
    "port": 8080
  },
  "defaults": {
    "maxTokens": 2048,
    "temperature": 0.7,
    "topP": 0.9
  },
  "memory": {
    "reservePercent": 0.1
  }
}
```

## API 服务器

启动后提供 OpenAI 兼容接口：

```bash
mox run Qwen/Qwen2.5-0.5B-Instruct --port 8080
```

### 端点

| 端点 | 方法 | 描述 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/v1/models` | GET | 列出可用模型 |
| `/v1/chat/completions` | POST | 聊天补全 |

### 请求示例

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## 依赖

- [MLX Swift](https://github.com/ml-explore/mlx-swift) - Apple MLX 框架
- [swift-nio](https://github.com/apple/swift-nio) - 异步网络 (仅 Server)

无第三方下载库，使用原生 URLSession + HTTP Range。

## License

MIT License
