# MoxGUI — SwiftUI 客户端现状

> v0.10.1 状态盘点。`MoxApp.swift` 477 行 + `MainWindow.swift` 232 行 + `StatusBarController.swift` 78 行 + `DaemonModeDialog.swift` 70 行 = **857 行 Swift**。`MoxGUIClient`（`MoxAPIClient` + `AppStateHelpers`）≈ 469 行。本 README 描述 v0.10.1 各 tab 实际渲染的样子、什么工作、什么是 stub，**v0.11 P0.1 GUI chat UI 的工作范围就基于这张表**。

---

## 顶层窗口（`MainWindow`）

```
┌──────────────────────────────────────────────────────────────────────┐
│ Mox                                                 ◯ ◪ ◫             │  ← 窗口 chrome
├──────────────────────────────────────────────────────────────────────┤
│ [Chats] [Models] [Settings] [Logs]                                    │  ← TabView 4 个 tab
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  (active tab content)                                                 │
│                                                                       │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

`TabView` 4 个 tab，顺序固定。`@State private var selectedTab: Tab = .chats` 默认进 Chats。设计稿见 `docs/mox-gui-design.md`（如有）。

---

## 1. ChatsTab（v0.10.1 状态：🚧 STUB，v0.11 P0.1 实装）

```
┌─────────────────────────────────────────────────┐
│ Chats                                           │
│                                                  │
│  WIP — conversation list and message thread     │
│  land in the next milestone.                    │
│                                                  │
│  [Start a conversation (⌘N)]                    │  ← 唯一可交互控件
│                                                  │
│  (or, after ⌘N:)                                │
│  Active conversation id: 8a3b1f9c              │  ← UUID 文字，无用
│                                                  │
│                                                  │
│  (no input box)                                 │  ← **缺：用户连消息都发不出**
│                                                  │
│                                                  │
└─────────────────────────────────────────────────┘
```

**实际能力**：
- ✅ "Start a conversation" 按钮调 `appState.startNewConversation()`，分配一个 `Conversation` (UUID + title)。
- ❌ **没有输入框**。用户连消息都发不出。
- ❌ **没有消息流**。`Conversation.messages` 字段是空数组，没有 UI 渲染。
- ❌ **没有"发送"路径**。`AppState.sendUserMessage(text:)` **不存在**。
- ❌ **没有 model 选择**。不知道用哪个 model。
- ❌ **没有 tok/s 显示**。

**底层接口（已就位）**：
- `appState.client: MoxAPIClient?` ✅（HTTP + Process 两种实现都完成）
- `appState.currentConversation: Conversation?` ✅
- `appState.models: [ModelInfo]` ✅
- `MoxAPIClient.chat(modelId:messages:stream:)` ✅ 返回 `AsyncStream<String>`
- `MoxAPIClient.cancelChat()` ✅

**v0.11 P0.1 改造目标**：

```
┌─────────────────────┬───────────────────────────────────┐
│ Conversations       │  Qwen2.5-7B-Instruct-4bit ▾      │  ← 模型选择
│                     ├───────────────────────────────────┤
│ ▸ Chat #1   10:23   │                                    │
│ ▸ Chat #2   09:11   │  ┌─ you ──────────────────────┐   │
│   Chat #3   yesterday│  │ hello                         │   │
│   Chat #4   2d ago  │  └──────────────────────────────┘   │
│                     │                                    │
│                     │  ┌─ assistant ──────────────────┐ │
│                     │  │ Hi! How can I help you today? │ │
│                     │  │                       [34 t/s]│ │
│                     │  └──────────────────────────────┘   │
│ + New (⌘N)         │                                    │
│                     │  ▌ (正在生成)              [Stop]   │
│                     │                                    │
│                     ├───────────────────────────────────┤
│                     │ [Type a message...]   [Send ⌘↩]  │  ← 输入框
│                     │                                    │
│                     │ Model: Qwen2.5-7B  |  ⓘ settings  │
└─────────────────────┴───────────────────────────────────┘
```

**做法**（在 ROADMAP §P0.1）：
- `ChatsTab` 拆成 `HSplitView`：左 sidebar 列出 conversations（v0.12 持久化后才有列表项，v0.11 仍只 in-memory，但 UI 框先在）；右 detail 是真正的消息流。
- `MessageListView`：`ScrollViewReader` + `LazyVStack`，每条消息按 role 渲染气泡。
- `MessageInputView`：`TextField` + `Button("Send")` 调 `appState.sendUserMessage(text:)`。
- `AppState.sendUserMessage(text:)`：append user message → `client?.chat(modelId:, messages:, stream: true)` → iterate `AsyncStream<String>` → append assistant delta → 流式末尾把 usage / tok/s 写回 message metadata。
- `Stop` 按钮在流式生成中显示，调 `client?.cancelChat()`。
- 错误展示：assistant 气泡变红 + 重试按钮。

**不做**（v0.11 内）：Markdown 渲染、代码高亮、tool call 折叠 UI、多 model 对比、message 编辑/重生成。

---

## 2. ModelsTab（v0.10.1 状态：🟡 部分实装）

```
┌─────────────────────────────────────────────────┐
│ Models                                           │
│                                                  │
│  (empty state)                                   │
│  ┌───────────────────────────────────────────┐  │
│  │ ⏏  Detected: Apple M4, 16 GB RAM (small)  │  │  ← v0.10.1 新增
│  │                                            │  │
│  │  Recommended:                              │  │
│  │    • mlx-community/Qwen2.5-7B-Instruct-4bit │  │
│  │    • mlx-community/Meta-Llama-3.1-8B-...  │  │
│  │    • mlx-community/Qwen2.5-3B-Instruct-4bit │  │
│  │                                            │  │
│  │  Run: mox pull <id>  then  mox run <id>   │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  (or, if models installed:)                      │
│  ┌───────────────────────────────────────────┐  │
│  │ Qwen2.5-7B-Instruct-4bit   mlx-community  │  │
│  │                              4.1 GB        │  │  ← 仅展示，可读
│  │ Meta-Llama-3.1-8B-4bit     mlx-community  │  │
│  │                              4.5 GB        │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
└─────────────────────────────────────────────────┘
```

**实际能力**：
- ✅ 空状态显示 `HardwareSuggestionBanner`（v0.10.1 新增，~70 行 Swift）—— 检测 Apple Silicon、tier、推荐列表、复制可用的 `mox pull` 指令。
- ✅ 有 model 时显示 list，每行 `name + source + size`。
- ❌ **没有 Load / Unload 按钮**（v0.11 P1.2 要补）—— `/v1/models/{id}/load|unload` endpoint 缺。
- ❌ 没有"删除"按钮（用户得去 CLI `mox delete`）。
- ❌ 没有 model detail 面板（quantization、family、context window、tool call 支持）。
- ❌ 没有按 kind 分组（v0.11 P2.1 embedding 模型接入后才有需求）。

---

## 3. SettingsTab（v0.10.1 状态：✅ 实装）

```
┌─────────────────────────────────────────────────┐
│ Settings                                        │
│                                                  │
│  ┌─ Server ──────────────────────────────────┐  │
│  │ Host  [127.0.0.1      ]                  │  │  ← 双向绑定 AppConfig.server
│  │ Port  [11555         ]                   │  │
│  │ Status ● Running                          │  │  ← 绿/黄/红
│  │ [Reload settings from disk]              │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  ┌─ Generation defaults ──────────────────────┐  │
│  │ max_tokens   [2048     ]                  │  │  ← AppConfig.defaults
│  │ temperature  [0.7      ]                  │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  ┌─ Daemon ──────────────────────────────────┐  │
│  │ ☑ Run as launchd daemon                   │  │  ← AppConfig.daemon
│  │ Path: ~/Library/LaunchAgents/...plist     │  │
│  │ [Install daemon] [Uninstall daemon]       │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
└─────────────────────────────────────────────────┘
```

**实际能力**：
- ✅ Host / Port 双向绑 `AppConfig.server`，改完自动写 `~/.mox/config.json`。
- ✅ Daemon enable toggle，调 `launchctl load/unload`。
- ✅ Status 指示（绿/黄/红）根据 `mox-server status` / `/health` 状态。
- ✅ `max_tokens` / `temperature` 改 server defaults。
- ❌ **没有"显示 Hardware" 按钮**（v0.11 P0.1 / Settings 顺手补）—— 调 `HardwareSuggestion.current()` 重跑一次。
- ❌ 没有"数据目录" 跳转（`mox debug open-data-dir` 有 CLI 但 GUI 没暴露）。

---

## 4. LogsTab（v0.10.1 状态：🚧 STUB）

```
┌─────────────────────────────────────────────────┐
│ Logs                                            │
│                                                  │
│  WIP — log filter + tail view of                 │
│  `~/Library/Logs/Mox/` arrive next milestone.    │
│                                                  │
│                                                  │
│  (no logs visible)                               │
│                                                  │
└─────────────────────────────────────────────────┘
```

**实际能力**：
- ❌ 完全是占位文字。**0 行 log 渲染代码**。
- `MoxCore` 有 `os.Logger` 在用（v0.8.0 引入），但 GUI 没订阅。

**不在 v0.11 范围**。Logs tab 是 v0.12+ 议题（要选 tail / filter / follow / 持久化到 file）。

---

## StatusBarController（v0.10.1 状态：✅ 实装，但薄）

- macOS 状态栏图标 + 下拉菜单。
- `StatusBarController.activate(currentModel:)` 在 daemon mode 进入时调。
- 菜单项：`Open Mox Window` / `Status: <state>` / `Quit`。
- ❌ 没有"当前 model" 显示（v0.11 P0.1 GUI 改完顺手补）。

---

## DaemonModeDialog（v0.10.1 状态：✅ 实装）

启动时探测 daemon 状态 → 弹模态：
- **detected**：直接进主窗口，daemon 模式。
- **not detected**：弹 dialog 问用户 `Use temporary process mode` / `Install daemon first` / `Quit`。
- **error**：显示错误信息 + 重试。

✅ 已实装，~70 行。

---

## 综述：v0.10.1 GUI 实际功能 vs 设计稿

| 设计稿功能 | v0.10.1 状态 | 阻塞 |
|------------|-------------|------|
| 启动探测 daemon + dialog | ✅ | — |
| 4-tab 主窗口框架 | ✅ | — |
| Settings tab 完整 | ✅ | — |
| Status bar 状态栏 | ✅ 但薄 | — |
| Models list | ✅ 仅展示 | P1.2 加 Load/Unload |
| Hardware-aware 空状态 banner | ✅ v0.10.1 | — |
| **Chat: 输入 + 消息流 + tok/s** | ❌ **0 行** | **P0.1 必补** |
| Logs: tail / filter | ❌ | v0.12+ |
| Markdown / 代码高亮 | ❌ | v0.12+ |
| 持久化对话 | ❌ in-memory | P2.4 |
| Model 详情面板 | ❌ | v0.12+ |
| Tool call 折叠 UI | ❌ | P1.4 后 |

**v0.10.1 的 GUI 本质**：是一个**能看不能聊的设置面板**。`MoxAPIClient.chat()` 全套接口都就位了，但 SwiftUI 视图层没接。

**v0.11 P0.1 GUI chat UI 是 mox 客户端从"骨架"变成"应用"的临界点**。
