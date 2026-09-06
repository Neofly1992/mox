# Mox 续接入口

更新：2026-09-07。新会话先读此文，再按任务读对应规格；无需旧会话上下文。

## 1. 当前状态

- 用户已确认按新架构重写，并授权完成保存旧状态、创建分支、替换旧工程三步；已完成。
- 分支 `codex/rewrite`；旧实现快照 `845470a`；新基础提交 `c3b9e2d`。开始时用 git status/log 核实最新状态，不强制回退到这些提交。
- M1 实现中：Domain/Core、官方 MLX adapter 与最小 CLI 已实现；15 项自动测试通过；全新 `.build/m1-tests` 中真实推理连续三次通过，最终 CLI 全场景通过。旧增量目录曾出现异常派发，已改为隔离测试构建并保留异常记录；验收报告正在整理；尚未人工验收。
- 完整 Xcode 26.6 (17F113) 初始化通过。SwiftData 独立进程写入/重开通过；新骨架 swift build 通过。MLX 与 CLI Metal 资源现已真实验证；App 和对外协议仍不在 M1 范围。
- 不再有“先修好旧工程”“先安装 Xcode”的前置任务。沙箱曾阻止 Swift 宏插件/缓存访问，沙箱外成功；不要误诊为工具链损坏。
- 本任务起点 `f898817`；已有未提交工程原则文档完整保存为 `68368b1`。M1 主实现提交 `0ef7fec`；资产一致性修复 `298f289`，为 Core 最终被测版本；CLI 非阻塞 stdin、产物工程外搬迁和重复打包已于 2026-09-07 复测通过；不推送、合并或发布。固定依赖与实施边界见技术设计 §13、docs/DEPENDENCIES.md。

## 2. 必须保留的方向

必读 ARCHITECTURE-DRAFT 第 0 节的集中工程原则；CONTRIBUTING 已明确规格审阅分工与独立阶段审查建议。用户无需逐行看技术规格，实质产品/架构取舍应单独说明。

Apple Silicon macOS 专用；优先 Apple 原生和成熟社区方案；复用官方 MLX。没有已发布兼容性负担，允许重新设计，不能因旧实现方便而保留错误边界。

独立 .app 无需 brew/Python 即可使用；Homebrew 只是分发和可选服务托管。rootless；GUI 自己启动的 worker 与既有前台/brew 服务有明确所有权；不重复启动或误停外部服务。

Swift/SwiftUI/SwiftData 已选定。推荐 Hummingbird、URLSession 本地 HTTP；ModelScope 有官方 Python Hub SDK，但当前方案为 Swift 薄适配。详细取舍见技术方案及竞品补充，不重开无证据的选型讨论。

GUI 基础聊天试用模型，对外提供 OpenAI/Anthropic 协议。首版文本与工具调用；多模态明确后续必做，内容块/媒体边界现在设计。Pi 为后续可选轻量集成，不实现自己的完整 agent。

HF/ModelScope 和同协议自定义来源、镜像；精确 revision 安装与原子提交；请求自动加载已安装模型，不自动下载。资源预留、lease、取消并等待、失败回滚属于正确性，不能当成可省略的性能优化。

## 3. 阅读顺序与文档职责

所有实现会话先遵循 [CONTRIBUTING](../CONTRIBUTING.md) 的入口、自测、出口和人工验收流程。规格/报告模板位于 `docs/templates/`；[发布计划](RELEASE-PLAN.md)、[M1 详细规格](milestones/M1.md)、M2–M4 概要已建立。M1 验收报告在最终出口时建立；其余阶段尚未实现。

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

M1 继续完成最终出口：运行 `scripts/test-m1-real.sh`、`scripts/test-m1-cli.py`，记录真实慢消费者、日志和构建结果；创建 `docs/acceptance/M1.md`，更新本文件并提交。

真实测试模型已在 `.build/test-models/qwen2.5-0.5b-4bit`，来源/revision/SHA256 见依赖文档。Metal Toolchain 17F109 已安装；可复现构建为 `scripts/build-m1.sh`，产物 `.build/m1/mox`。无需重新排查 Xcode。

尚未获得人工验收，不进入 M2。完成后另一个会话可按起止提交独立审查；此安排不自动启动子代理。

## 6. 交接维护

每次更新替换过期的“当前状态/下一步”，不要不断追加互相矛盾的待办。记录可复现命令和结果，临时目录仅作为辅助证据（可能被清理）。不要保存密钥、完整私人对话或机器敏感配置。新增设计决策写回规格，必要时注明仍为建议。
