# Mox 续接入口

更新：2026-09-07。新会话先读此文，再按任务读对应规格；无需旧会话上下文。

## 1. 当前状态

- 用户已确认按新架构重写，并授权完成保存旧状态、创建分支、替换旧工程三步；已完成。
- 分支 `codex/rewrite`；旧实现快照 `845470a`；新基础提交 `c3b9e2d`。开始时用 git status/log 核实最新状态，不强制回退到这些提交。
- **M1 待人工验收**：本地只读模型加载、官方 MLX 流式生成、取消并等待、再次生成、多轮最小 CLI 已完成。18 项自动规则/状态测试通过；交付代码 `9df437b` 的真实推理集成测试通过；2026-09-07 最终 CLI 的 PTY、退出码、满管道、产物搬迁、Unicode 路径、禁网与模型不改写测试通过。
- [M1 交付报告](acceptance/M1.md)提供逐要求证据、5 个人工操作场景、限制和失败修复记录；[机器证据](acceptance/M1-evidence.json)记录版本、模型、统计和产物哈希。同会话 review-agent 的两项 P2（Unicode 增量、终端超限退出码）已修复并复测；独立会话审查未进行，用户尚未验收。
- 阶段代码范围 `f898817..9df437b`；交付报告与 HANDOFF 独立作文档提交。仅本地提交，未推送、合并或发布。
- 完整 Xcode 26.6、Swift 6.3.3、Metal Toolchain 17F109 已就绪；Apple M4/16 GiB/macOS 26.6.2 实测。固定 MLX/LM 依赖与资源策略见技术设计 §13、[依赖说明](DEPENDENCIES.md)。macOS 15 部署目标尚无真机证据。
- 旧 `.build` 增量产物曾出现模块/派发异常，历史证据见 Git；测试脚本使用隔离的 `.build/m1-tests` 后连续通过。不要复用旧测试产物或重做旧 Xcode 阻塞排查。App、HTTP、下载与持久化未实施，M2 尚未开始。

## 2. 必须保留的方向

必读 ARCHITECTURE-DRAFT 第 0 节的集中工程原则；CONTRIBUTING 已明确规格审阅分工与独立阶段审查建议。用户无需逐行看技术规格，实质产品/架构取舍应单独说明。

Apple Silicon macOS 专用；优先 Apple 原生和成熟社区方案；复用官方 MLX。没有已发布兼容性负担，允许重新设计，不能因旧实现方便而保留错误边界。

独立 .app 无需 brew/Python 即可使用；Homebrew 只是分发和可选服务托管。rootless；GUI 自己启动的 worker 与既有前台/brew 服务有明确所有权；不重复启动或误停外部服务。

Swift/SwiftUI/SwiftData 已选定。推荐 Hummingbird、URLSession 本地 HTTP；ModelScope 有官方 Python Hub SDK，但当前方案为 Swift 薄适配。详细取舍见技术方案及竞品补充，不重开无证据的选型讨论。

GUI 基础聊天试用模型，对外提供 OpenAI/Anthropic 协议。首版文本与工具调用；多模态明确后续必做，内容块/媒体边界现在设计。Pi 为后续可选轻量集成，不实现自己的完整 agent。

HF/ModelScope 和同协议自定义来源、镜像；精确 revision 安装与原子提交；请求自动加载已安装模型，不自动下载。资源预留、lease、取消并等待、失败回滚属于正确性，不能当成可省略的性能优化。

## 3. 阅读顺序与文档职责

所有实现会话先遵循 [CONTRIBUTING](../CONTRIBUTING.md) 的入口、自测、出口和人工验收流程。规格/报告模板位于 `docs/templates/`；[发布计划](RELEASE-PLAN.md)、[M1 详细规格](milestones/M1.md)、M2–M4 概要已建立。[M1 交付报告](acceptance/M1.md)已建立；其余阶段尚未实现。

1. [技术方案](architecture/TECHNICAL-DESIGN.md)：写代码前必读，模块边界、状态/协议/存储契约、G0–G7 验收。具体依赖版本仍需实施时核验锁定。
2. [产品契约](../ARCHITECTURE-DRAFT.md)：理解功能与默认行为；产品问题查这里。
3. [竞品与选型](architecture/COMPETITOR-AND-SELECTION-REVIEW.md)：做下载、进程、GUI、协议时查对应能力矩阵，避免遗漏工程保障。
4. [执行历史](architecture/REWRITE-EXECUTION.md)：仅在需追溯时阅读；早期阻塞不是当前待办。

旧 REVIEW 文档与 Git 快照只用于查证问题，不是新实现规格。规格冲突时以最新用户明确决策为准并同步文档；本文件的进度覆盖历史记录，技术细节以技术方案为准。

## 4. 实施里程碑概要

按模块组织，按端到端链路交付，不先写完整 Core 再接 UI，也不一次性建立全部空模块。

| 阶段 | 实现范围 | 完成条件 |
| --- | --- | --- |
| M1 本地模型 | Domain/Core、MLX adapter、最小 CLI | 本地目录加载→流式生成→取消并等待→再次生成；失败回滚、资源回收、结构化日志；真实小模型证据 |
| M2 GUI/服务 | Server、Client、Bootstrap、基础 App 和聊天持久化 | GUI 自启/连接服务、流式显示/停止/恢复；所有权、异常和迟到事件正确 |
| M3 获取/管理 | Sources、模型 Persistence、CLI/GUI 管理 | HF/ModelScope 下载→安装→聊天；镜像/鉴权、恢复、磁盘不足、删除语义 |
| M4 0.1 原型 | 标准协议、工具调用、本地 App | 两种协议真实测试程序、下载聊天闭环、用户本机验收 |
| P1 后续公开发布 | 签名公证、干净环境、可选 Homebrew | 用户决定发布后另行细化与验收 |

G0–G7 是技术验收维度，M1–M4/P1 是交付顺序；相关验证随新代码进行，不再用一轮独立预研阻挡重写。0.1 不包含 Pi、复杂调度或多模态实现，但保留已约定边界。

## 5. 下一步

1. 用户按 [M1 交付报告](acceptance/M1.md)的 5 个场景试用；仅收到明确反馈后更新“已验收”。
2. 可由独立会话审查 `f898817..9df437b` 的代码及后续验收文档提交，重点核验资源所有权、取消、引用一致性和证据；不自动创建任务或子代理。
3. 人工或审查发现问题则修复并针对性复测；M1 人工验收通过后才进入 M2。

直接启动：

```sh
/Users/neo/Code/personal/mox/.build/m1/mox chat --model-path /Users/neo/Code/personal/mox/.build/test-models/qwen2.5-0.5b-4bit
```

模型的固定来源/revision/SHA256 见依赖文档；模型不提交到 Git。可复现构建为 `scripts/build-m1.sh`，真机测试为 `MOX_TEST_MODEL="$PWD/.build/test-models/qwen2.5-0.5b-4bit" scripts/test-m1-real.sh`。完整命令与诊断位置在报告中，无需查源码。

## 6. 交接维护

每次更新替换过期的“当前状态/下一步”，不要不断追加互相矛盾的待办。记录可复现命令和结果，临时目录仅作为辅助证据（可能被清理）。不要保存密钥、完整私人对话或机器敏感配置。新增设计决策写回规格，必要时注明仍为建议。
