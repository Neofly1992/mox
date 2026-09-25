# Mox 续接入口

更新：2026-09-25。新会话先读此文，再按任务读对应规格；无需旧会话上下文。

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

所有实现会话先遵循 [CONTRIBUTING](../CONTRIBUTING.md) 的入口、自测、出口和人工验收流程。规格/报告模板位于 `docs/templates/`；[发布计划](RELEASE-PLAN.md)、[M1 详细规格](milestones/M1.md)、M2 详细规格及 M3–M4 概要已建立。[M1 交付报告](acceptance/M1.md)已建立；[M2 交付报告](acceptance/M2.md)提供最终证据与六个人工验收场景。

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

- 分支 `codex/rewrite`；M2 与 M3 实现、测试和验收材料已提交并推送至 `origin/codex/rewrite`（`d0fb959`）；开始前仍须检查 Git 状态并保护后续修改。未合并或发布。
- **M2：R1–R3 已定向复核通过，完整人工验收仍待用户完成。** 直接核对重试保留草稿、历史分页/迁移、Cocoa/POSIX 安全诊断并运行 6 项定向回归；证据与人工状态见[审查](reviews/M2-2026-09-21.md)及[报告](acceptance/M2.md)。用户仅表示试用看上去没有问题并授权继续 M3。
- **M3：R1–R3 原缺陷修复已于 2026-09-25 定向复核，仍有验证缺口和人工验收未完成。** [独立审查报告](reviews/M3-independent-2026-09-24.md)记录原问题；[M3 规格](milestones/M3.md)、[技术设计](architecture/TECHNICAL-DESIGN.md)已更新有界库查询与独立存储记录；[M3 交付报告](acceptance/M3.md)及[机器证据](acceptance/M3-evidence.json)记录最新结果。本轮独立复跑 5 个相关测试函数通过（含 3 个损坏参数用例），范围与限制见独立审查报告末节；不等于完整验收。
- 当前源码全量自动测试 84 项通过（`.build/m3-r3-final-tests.log`），大库最终夹具定向复测通过（`.build/m3-r3-large-library-final.log`）；GUI 真实 HF 预检→下载→安装→详情→聊天及镜像表单保留均通过（`.build/m3-r3-ui-rerun.log`）。此前 HF/ModelScope 两源各 9 文件、289,598,797 字节的精确版本安装及真实 MLX 聊天，以及真实暂停→重启→继续，证据见交付报告。旧 SwiftData 库用户默认来源迁移与重开记录顺序已验证。
- 当前 Release App `.build/m3/Release/Mox.app`、CLI `.build/m3-worker/Release/mox`，buildID `mox-m3-e5a062f7623cd09d7fdd853905f38c1db243fed48e7142ea3a1bbaeac602f447`；内嵌 worker 与 CLI 版本一致（`.build/m3-r3-release-build.log`）。真实 HF Release 预检与无现成服务的 CLI `models pull` 安装通过（`.build/m3-r3-real-plan.log`、`.build/m3-r3-real-pull.log`）。GUI 自动测试在匹配的 Debug 业务源码与 worker 上通过；Release UI 未单独自动跑。
- **下一步：可开始 M4 规格细化；编码入口先收尾 M3 可自动完成的验证，再记录用户验收。** 外部已有服务的 CLI 生命周期、真实私有镜像、物理断网、真实 MLX 推理与删除竞态、多进程双客户端、macOS 15 真机尚未实测；有相应可控边界测试的项目见交付报告。不要把这些写成已通过。M2 完整人工验收仍待用户完成；M4 实现尚未开始；未合并或发布。

## 6. 交接维护

每次更新替换过期的“当前状态/下一步”，不要不断追加互相矛盾的待办。记录可复现命令和结果，临时目录仅作为辅助证据（可能被清理）。不要保存密钥、完整私人对话或机器敏感配置。新增设计决策写回规格，必要时注明仍为建议。
