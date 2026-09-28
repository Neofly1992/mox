# Mox 续接入口

更新：2026-09-28。新会话先读此文，再按任务读对应规格；无需旧会话上下文。

## 1. 当前状态

- 用户已确认按新架构重写，并授权完成保存旧状态、创建分支、替换旧工程三步；已完成。
- 分支 `codex/rewrite`；旧实现快照 `845470a`；新基础提交 `c3b9e2d`。开始时用 git status/log 核实最新状态，不强制回退到这些提交。
- **M1 已人工验收**：本地只读模型加载、官方 MLX 流式生成、取消并等待、再次生成、多轮最小 CLI 已完成。20 项自动规则/状态测试通过；交付代码 `967c6fb` 的真实推理集成测试通过；2026-09-08 交付 CLI 的 PTY、退出码、满管道、产物搬迁、Unicode 路径、禁网与模型不改写测试通过。
- [M1 交付报告](acceptance/M1.md)提供逐要求证据、5 个人工操作场景、限制和失败修复记录；[机器证据](acceptance/M1-evidence.json)记录版本、模型、统计和产物哈希。同会话 review-agent 的两项 P2（Unicode 增量、终端超限退出码）已修复并复测；独立会话审查已完成，R1 诊断缺口已在 `967c6fb` 修复并由实现者复测，M2 续接会话已完成 R1 定向代码/测试复核（不含重新采集故障日志），见 [审查报告](reviews/M1-2026-09-08.md)；用户2026-09-08明确反馈“M1已经测试OK了”。
- 阶段代码范围 `f898817..967c6fb`；交付报告与 HANDOFF 独立作文档提交。仅本地提交，未推送、合并或发布。
- M1 验证环境为 Xcode 26.6、Swift 6.3.3、Metal Toolchain 17F109、Apple M4/16 GiB/macOS 26.6.2；当前 M2 使用 macOS 27 / Xcode 27 / Swift 6.4 与匹配 Metal Toolchain。固定 MLX/LM 依赖与资源策略见技术设计 §13、[依赖说明](DEPENDENCIES.md)。macOS 15 部署目标尚无真机证据。
- 旧 `.build` 增量产物曾出现模块/派发异常，历史证据见 Git；测试脚本使用隔离的 `.build/m1-tests` 后连续通过。M2 的模型工作台、HTTP、进程所有权和聊天持久化已实现，三项独立审查问题已修复并经 M3 续接定向复核；当前为**待完整人工验收**。用户授权在复核无阻塞后推进 M3，不能推定已完成 M2 人工验收。

## 2. 必须保留的方向

必读 ARCHITECTURE-DRAFT 第 0 节的集中工程原则；CONTRIBUTING 已明确规格审阅分工与独立阶段审查建议。用户无需逐行看技术规格，实质产品/架构取舍应单独说明。

Apple Silicon macOS 专用；优先 Apple 原生和成熟社区方案；复用官方 MLX。没有已发布兼容性负担，允许重新设计，不能因旧实现方便而保留错误边界。

独立 .app 无需 brew/Python 即可使用；Homebrew 只是分发和可选服务托管。rootless；GUI 自己启动的 worker 与既有前台/brew 服务有明确所有权；不重复启动或误停外部服务。

Swift/SwiftUI/SwiftData 已选定。推荐 Hummingbird、URLSession 本地 HTTP；ModelScope 有官方 Python Hub SDK，但当前方案为 Swift 薄适配。详细取舍见技术方案及竞品补充，不重开无证据的选型讨论。

GUI 基础聊天试用模型，对外提供 OpenAI/Anthropic 协议。首版文本与工具调用；多模态明确后续必做，内容块/媒体边界现在设计。Pi 为后续可选轻量集成，不实现自己的完整 agent。

HF/ModelScope 和同协议自定义来源、镜像；精确 revision 安装与原子提交；请求自动加载已安装模型，不自动下载。资源预留、lease、取消并等待、失败回滚属于正确性，不能当成可省略的性能优化。

## 3. 阅读顺序与文档职责

所有实现会话先遵循 [CONTRIBUTING](../CONTRIBUTING.md) 的入口、自测、出口和人工验收流程。规格/报告模板位于 `docs/templates/`；[发布计划](RELEASE-PLAN.md)、[M1 详细规格](milestones/M1.md)、M2/M3 详细规格及 M4 可实施规格已建立。[M1 交付报告](acceptance/M1.md)已建立；[M2 交付报告](acceptance/M2.md)提供最终证据与六个人工验收场景。

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
| M2 GUI/服务 | Server、Client、Bootstrap、模型工作台与测试会话持久化 | 模型→详情→测试；自启/连接服务、流式显示/停止/恢复；所有权与异常正确 |
| M3 获取/管理 | Sources、模型 Persistence、CLI/GUI 管理 | HF/ModelScope 下载→安装→聊天；镜像/鉴权、恢复、磁盘不足、删除语义 |
| M4 0.1 原型 | 标准协议、工具调用、本地 App | 两种协议真实测试程序、下载聊天闭环、用户本机验收 |
| P1 后续公开发布 | 签名公证、干净环境、可选 Homebrew | 用户决定发布后另行细化与验收 |

G0–G7 是技术验收维度，M1–M4/P1 是交付顺序；相关验证随新代码进行，不再用一轮独立预研阻挡重写。0.1 不包含 Pi、复杂调度或多模态实现，但保留已约定边界。

## 5. 下一步与当前证据

- 分支 `codex/rewrite`。用户于 2026-09-28 授权实施 M4，并随后授权将本轮工作 commit、push 到当前远端分支；准确提交与远端状态以 Git 为准。开始前已有的 `docs/reviews/M3-independent-2026-09-24.md` 未提交复核补记未纳入 M4 提交，勿覆盖。新会话仍须先看 Git 状态与实际源码。
- M4 本机公共 API、独立 Keychain key、GUI/CLI 控制、两协议严格 DTO/SSE、真实工具事件与 Qwen3 模板、可取消的有界流已实现。同会话审查及 2026-09-28 独立审查的 R1/R2 已由实施者修复并自测，尚待独立复核；当前 Release App `.build/m4/Release/Mox.app`，buildID `mox-m4-286ce3dd39dd651231aa0a02ddd04279a0f85a494cbd90258bb17fb702f36684`。工具能力仅对固定 revision 及权重/tokenizer 摘要匹配的受管 Qwen3 安装开放；导入引用不能只凭 `model_type` 获得能力。完整要求与证据见 [M4 规格](milestones/M4.md)、[M4 验收报告](acceptance/M4.md)，跨模块边界见[技术设计 §7–§10](architecture/TECHNICAL-DESIGN.md)。不要从 HANDOFF 推导具体字段或状态规则。
- 官方 `openai==3.19.2`、`anthropic==1.8.0` 已对新 Release worker 运行文本、流式、固定 Qwen3 的客户端纯函数工具往返、流式工具参数拼接、Anthropic 错误结果续答和真 HTTP 失败路径；可复跑入口为 `scripts/verify-m4-sdk.py`。独立审查修复后全量普通 Swift 测试四组 7+49+10+33 项无失败，3 项条件测试按标记跳过；MLX 实跑 3 项的证据来自修复前，所触 MLX 路径未变。新 Release 对未终止 body 的 401/403/413、读取期限、非法跨轮工具历史 400 与后续正常请求均真 HTTP 通过。Release 三项 UI 测试证据来自本次修复前，未当作新构建复跑。命令、日志与限制见 [M4 报告](acceptance/M4.md)。M3 自动入口检查证据仍在报告，勿把历史 M3 R1–R3 重审或将建议写成已运行。
- M2、M3、M4 的完整用户体验验收尚未获得用户明确反馈。真实私有镜像与 macOS 15 真机依赖外部资源，报告为 BLOCKED；不让用户代做基础正确性测试。M4 本机原型边界不含 Responses、Pi、容器 agent、多模态推理、签名公证或 Homebrew 发布。
- 2026-09-28 [M4 独立审查](reviews/M4-independent-2026-09-28.md)确认 R1 提前拒绝连接未释放、R2 工具结果跨轮接受；本会话已修复、增加两协议负向 fixture 与真 socket 探针，并在新 Release 上自测通过。原独立审查记录不改成通过；M4 当前为**待独立复核及人工验收**。
- **下一步**：由独立会话定向复核 R1/R2 的新源码及真 socket 证据，再完成 M4 报告末节的用户人工体验场景并记录明确结论。用户当前先将源码推到 GitHub，尚未要求打正式发布标签或分发二进制；签名、公证与 Homebrew 不是源码推送的前置条件。

## 6. 交接维护

每次更新替换过期的“当前状态/下一步”，不要不断追加互相矛盾的待办。记录可复现命令和结果，临时目录仅作为辅助证据（可能被清理）。不要保存密钥、完整私人对话或机器敏感配置。新增设计决策写回规格，必要时注明仍为建议。
