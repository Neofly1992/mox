# 架构与工程原则

这是当前源码的职责与关键不变量。[产品契约](PRODUCT.md)规定可见行为，[API](API.md)规定外部协议，[开发说明](DEVELOPMENT.md)规定验证入口。

## 0. 工程原则

- 正确性优先。不能因旧实现、已有投入、代码生成方便或暂时能运行接受错误边界；不建立永久过渡层。
- 单一业务权威。相同规则由正确模块拥有，GUI/CLI/HTTP/provider 不复制业务；通过小协议、明确 ports 和依赖注入表达真实变化边界。
- Apple 原生优先，复用官方 MLX。实践须由官方资料、锁定源码和实际验证支持，不盲追新版本或因品牌忽略缺陷。
- 源码原型仍须可靠、可诊断、可恢复、有资源边界和关键回归。编译与 mock 通过不等于真实路径完成。
- 未发布实现无兼容包袱；用户模型、对话、凭据及对外协议仍须保护。数据删除必须有真实授权。
- 人和模型均应能从命名、类型、控制流及相邻契约维护代码。抽象降低理解成本，不追求最少行数或最多层级，不建设假想平台。
- 唯一当前平台是 arm64 macOS，运行技术是 MLX。多模态领域边界保留，媒体处理和 agent 实现后置。
- 工程可贡献：可重复构建、锁定依赖、许可证、可信测试及诚实验证记录。用户指令优先，保留其他任务的修改。

## 1. 模块与依赖

| 模块 | 职责 |
| --- | --- |
| MoxDomain | 身份、请求/消息/事件/错误、参数规则的值类型 |
| MoxCore | ModelLibraryService 完整模型用例；DownloadManager 下载/恢复；RuntimeCoordinator 资源与执行准入 |
| MoxMLX | 官方模型 factory、tokenizer、模板、生成、工具 parser、真实统计与 GPU 停止适配 |
| MoxSources | HF 官方元数据能力与 ModelScope URLSession 薄适配、文件传输和 Keychain 来源凭据 |
| MoxPersistence | SwiftData 运行索引/配置/任务与 GUI 历史；明确保存、身份查询和分页 |
| MoxProtocol / Server | 私有 DTO、公开协议编解码、鉴权、HTTP body/连接/流生命周期 |
| MoxClient / Bootstrap | URLSession 有界传输、实例握手、锁/发现、worker 所有权与停止 |
| MoxChat / App / CLI | 聊天状态、原生界面和命令交互；不复制服务业务规则 |

Core 不依赖 HTTP DTO、SwiftUI、SwiftData 或具体 provider。ModelRuntime、ModelSourceFactory、ModelLibraryPersistence 是真实依赖边界；composition root 注入实现。来源/凭据事务、模型删除准入、参数解析与 pin 协调在 Core，直接 Core 调用同样受保护。危险元数据写入不作为公共用例。

App 链接 Client/Chat/Persistence 等，MLX 和 Server 位于独立 worker，避免 GUI 承担 GPU 对象。SwiftPM 管理库/CLI/依赖；生成的 Xcode project 管理 App、嵌入 worker 和 UI tests。只有一套业务源码。

## 2. 服务和请求生命周期

canonical data-root 的跨进程 flock 是所有权依据，不以 PID、端口或文件存在猜测。run 目录 0700，discovery 0600，客户端核对实例 UUID、PID/所有权、wire 版本与源码指纹；实例 token 不写日志或 argv。版本不匹配不做旧原型协议兼容。

管理与公开推理是两个随机 loopback listener，公开默认关闭，两个凭据域分离。选择鉴权 HTTP 是为了让 App-owned、CLI 临时和前台服务共用发现/Client，并与公开协议共享框架；不要求注册 Mach service。限制是不能抵御同一用户的恶意进程；若未来需要签名调用方身份隔离，应重新评估 XPC，而不是把 bearer token 描述为系统安全沙箱。当前不预建可切换 IPC 框架。

先建立退出/父控制，再初始化 store、拥有后台恢复任务、绑定 listener 并原子发布 discovery。15 秒探活只约束连接建立，不等模型库 hash。libraryRecovery 与模型 checking/ready/missing/corrupt 独立，单个损坏不阻断服务。

Server 在耗时校验前登记请求与可取消句柄。Core 句柄拥有准备、校验等待、后端执行到实际停止；元数据拒绝仍走 HTTP 错误，接受后的失败是有界事件。取消自己的等待不取消库拥有的共享校验，后续取消检查阻止进入 Runtime。共享校验最多两个模型并行，有独立所有者与 shutdown barrier。HTTP FIN 可等心跳写失败检测，不能承诺瞬时停止；显式取消与 RST 独立验证。

SSE 有背压、心跳、写期限和唯一终态；未消费完 body 即拒绝时响应后关闭连接，绝不等待无限上传。body 聚合前限额、读取绝对期限和 idle 期限归 Server。公开错误/事件区别见 API；拒绝请求与已接受流断连不混淆。客户端不自动重放，重连取 snapshot，终态详情有有界保留。

服务 shutdown 拒绝新工作、取消并等待请求/后端和库级工作、保存持久状态、关闭 HTTP、删除己方 discovery、释放锁。App-owned 使用父控制管道，EOF 触发停止；外部服务不依赖 GUI 管道，不由 GUI 终止。

## 3. 身份、获取和恢复

来源身份是 registry UUID + repository + 不可变 revision + variant，目录按 artifact 摘要定位，alias 不是存储主键。镜像只是同来源访问端点，不改变身份；凭据限定授权 origin，跨 origin 重定向不转发。

HF 使用锁定官方 swift-huggingface 的元数据、分页、认证接口，字节传输用原生 URLSession 到本产品 staging；不触碰全局 HF cache。ModelScope 参考官方 Hub 的 HTTP 约定实现 Swift 薄适配，避免 Python 运行依赖；承担 provider 协议变化的维护成本。必要资产由格式检查器决定，不把 config 存在当作完整模型。

先解析精确版本/空间，暂存文件，再核对相对路径、长度、内容摘要与 config/分片索引，写 manifest，原子 rename，随后分别提交安装索引及任务终态。文件与数据库不是跨资源原子事务；正常继续与启动恢复共享幂等补全，覆盖文件已提交未建索引、索引已提交未存终态。必须核对实际 manifest、字节和持久计划；冲突保留证据，不宣布 installed。保留已有 ID、alias、pin、采样设置。已提交快照不覆盖。

恢复句柄是优化，不保证任意崩溃后 byte resume。已完成文件复用，失效 partial 明确重下；内容 digest、Git blob ID、opaque ETag 分开处理。缺文件/摘要不符/manifest 损坏标记不可用，保留可移除记录。

本地引用规范化路径（本地资产链接解析到目标，权重字节与修改时间取目标普通文件），读取前拒绝特殊文件；打开采用非阻塞及 no-follow，再按描述符核对普通文件类型和身份，分块读取检查取消。检查必要资产与有界 safetensors header/index；加载前后检查资产大小/修改时间，不声称能防止其他进程改写；同长度内容修改且时间戳被保留或文件系统时间分辨率不足时，元数据检查可能无法发现。受管安装的完整性校验另用 manifest 内容摘要。移除不删除原文件；模型使用/准备和删除按 Core 门闩协调。

## 4. Runtime 与 MLX 边界

RuntimeCoordinator 是驻留、reservation、加载任务、lease、LRU 和 pin 的唯一运行权威。首次加载先发布共享 task，加载失败回滚额度；新一批请求可重试。actor 可重入不代表 GPU 串行，显式 FIFO 门闩覆盖 load/warmup/generate/unload。

当前同一时刻一个 GPU 高峰工作，可多模型驻留；队列默认 8、等待 60 秒，serve 可在已校验安全范围调节。预算估计区分 weights、加载峰值、KV、工作区和系统余量，未知/溢出维度拒绝；自动淘汰仅 idle/unpinned，确认真实释放后复用预算。pin 防自动淘汰，不绕过活动卸载准入。内存估算不是系统硬隔离，其他进程压力仍是风险。

锁定 MLX LM 的异步 generate 流存在无界缓冲，因此采用官方同步 callback 入口（上游已 deprecated），未自造迭代/采样/kernel。回调直达有界 Core handle，超限取消后明确失败；所有 GPU 工作 synchronize 后才回收 lease/发终态。升级必须重新核验缓冲和取消，不自动切回无界流。

增量文本按 Unicode scalar 与官方 tokenizer 解码，未完成 UTF-8 延迟，前缀被改写明确失败；不按 grapheme 索引丢组合字符。Qwen3 经官方模板 enable_thinking=false，工具内容逐标量交官方 ToolCallProcessor；完整 JSON 工具调用经验证后才发事件，协议层再分片，不声称模型逐 token 透传工具参数。

真实 usage、stop/length/toolCalls/cancelled 分开；stop 序列跨分片匹配且不泄露匹配文本。未知上游停止原因不猜成功。输入原文上限 1 MiB/token 上限 8192，输出 token 上限 8192 且受 context/预算约束；累计输出 16 MiB、最多 32 次工具调用、每次参数 64 KiB，具体单一常量在 Domain/Core。工具能力按固定产物摘要表准入，不凭名称放行。

## 5. 存储、配置与界面

RuntimeStore 的配置/安装/任务按身份分别查询与更新，关联 LibraryChanges 明确 save。摘要投影与完整 payload 同次保存；数据库原生索引支持 alias/path/artifact/family/阶段/稳定顺序和分页。摘要查询最多 100 项、传输页 25 项，恢复逐项读取完整 manifest；没有进度更新时整库读取、复制、diff 或无限全库缓存。

ConversationStore 由 GUI 侧唯一逻辑 writer 拥有，每个 store 由独立 ModelActor 隔离，容器构造串行。记录按稳定顺序分页；内容和参数的磁盘编码不依赖 HTTP DTO。磁盘 schema 是正式初始格式，未来发布后的演进另行设计；打开失败不能回退空库。备份与数据权限见 DATA。

显式 save 保证配置、任务和终态；流式 checkpoint 有命名节奏与有界队列，不依赖 autosave、不承诺逐 token 落盘。崩溃可能丢最后 checkpoint 后少量文本并标 interrupted。有效参数唯一规则是 Domain EffectiveSampling，逐字段来源可查询，启动覆盖不回写。ChatController 的预览与发送使用同一当前覆盖快照，解析仍由服务/Core 执行；预览任务由控制器拥有并取消，响应按读取 ID、连接 epoch、模型路径及覆盖值核对后才能更新界面。预览失败保留输入；后续编辑不能修改已经建立的生成请求。原生数值控件的程序刷新不代表用户覆盖意图，界面只提交聚焦编辑的值变化或明确回车，恢复默认先结束编辑。参数展开使用原生按钮与 SwiftUI 状态，避免嵌套 split view 内 DisclosureGroup 的约束循环。

GUI feature state 用 SwiftUI/Observation，必要系统交互用 AppKit。模型、下载、测试和 API 导航职责清晰，会话列表仅在测试内部；模型详情/列表不拥有业务任务。历史使用稳定 ID 与惰性分段，活动回复与已结束呈现分离；切换读取丢弃迟到结果，未保存 live 回复独立保留。

Unified Logging 按 storage/download/runtime/server/gui/process 分类，安全事件关联 request/operation/instance/model；导出有界脱敏 snapshot，不保存 prompt、工具输入、凭据或完整敏感路径。底层错误保留安全 domain/code/阶段，不转储任意 localizedDescription/userInfo；诊断获取失败明确标记，不伪装完整导出。

## 6. 构建和验证

VERSION 是产品版本唯一来源；build fingerprint 标识生产源码/锁文件/构建输入，wire version 标识协议。Debug/Release 配置单独报告，App、CLI 与嵌入 worker 指纹一致。产物相对 Bundle 定位资源，不依赖构建机 PATH。

二进制验证与普通 CI 分离，复用构建入口；Draft 发布检出明确标签 commit，校验 vVERSION，构建任务只读，仅上传任务使用 environment 保护下的短期 GITHUB_TOKEN contents: write，不维护额外 PAT。App ZIP 仅包含完整 bundle，解压后验证版本、ARM64、worker 身份、资源与 ad hoc 签名；未公证实验包须从实际 Release 附件完成真机及人工验收后再公开。失败重试新增附件，不移动标签、修改公开版本或删除既有附件。

规则、真实存储/HTTP、MLX、UI、SDK 与人工体验各自记录，不混用。测试只用隔离根和公开模型，故障注入测试正式纳入 Tests；历史评审材料从 Git 查阅。有效边界验证包括竞争启动、共享加载/校验、取消、慢消费者、提交不确定、重启、损坏/冲突、参数保存失败、隐私及模型引用所有权。具体入口见 DEVELOPMENT，验证范围见 VALIDATION。

## 7. 诊断、估算与压力

- Domain 的 ResourceAssessment、ResourceStatus、MemoryPressureLevel 和 BackendMemorySnapshot 是共享值。Core ModelResources 拥有稠密 attention 包络与判定，LocalModel 与远端小型 config 共用该规则；没有第二套预算器。ModelRuntime 暴露预算与 advisory assessment，RuntimeCoordinator 独占 reservation、门闩及压力状态。
- 权重基线为必要 safetensors 文件字节（含少量 header），加载多预留一份权重副本；KV 按层数 × K/V 两份 × KV heads × head dimension × Float32 四字节 × token 包络，工作区根据 hidden/intermediate/vocab 等实际维度预留投影与 MLP 临时缓冲，沿用有界 128-token prefill 包络与 64 MiB 下限；锁定 Gemma2 使用显式 attention score 矩阵，额外按 8 份 Float32 score buffer 保守预留。head_dim/KV heads 的默认与使用方式按锁定官方各模型配置核对，Qwen2/Phi3 不采用其后端忽略的 head_dim 字段，缺少必需维度不猜测。模型 context 与输入 8192/output 8192 的既有上限仍约束请求（Domain GenerationLimits 为唯一 token 上限定值，Core 与后端复用）。只有已核验稠密布局名单可估算；共享/滑动 attention 按完整 KV 保守计算，hybrid/MoE 等未知架构拒绝，CPU、tokenizer、分配器与加载转换成本有不确定性。输出已占满 context 时在加载前拒绝。
- MLX backend 报告 configured/device ceiling，Coordinator 将注入的 policy 上限收紧到该值，直接 Core 嵌入也不能提高原生安全上限；configured ceiling 继续取物理 RAM 的 65% 与 Metal recommendedMaxWorkingSetSize 的 80% 中较小者（系统保留至少 35%）；超过预算拒绝，使用超过预算的 80% 标记紧张。macOS free+inactive 页只是可回收页观测，不是“总内存减使用量”或进程可分配保证；每次门闩准入及确认卸载后重新采样，并留 20% 页余量。采样失败不冒充无限容量，仍执行 configured ceiling 与压力准入。`os_proc_available_memory` 在锁定 SDK 标注 API_UNAVAILABLE(macos)，不使用。
- Runtime 在门闩内原子检查/发布 reservation，再悬挂到后端；显式加载也计入官方 one-token warmup 的 KV/工作区包络，warmup 模板 token 超限会明确失败。队列保持既有容量/期限，同一模型复用驻留，串行高峰无需为等待请求分配 KV。预览包括当前 reservation，可能保守计入正在执行的请求，不提前淘汰模型；实际门闩可按 LRU 回收 idle/unpinned。固定与活动模型仍受原有生命周期保护。
- composition root 订阅 DispatchSourceMemoryPressure，并通过有界顺序事件流注入 Coordinator；规则测试直接注入信号。warning 拒绝新工作，critical 取消所有生成及门闩等待；加载不能保证即时停止，仍等待官方后端返回/同步。压力回收也持有同一门闩，卸载返回后才扣除权重；固定模型保留。normal 恢复延迟 5 秒，新的 warning/critical 取消恢复计时。退出取消恢复任务，并等待压力回收与后端停止。
- MoxMLX 通过锁定 mlx-swift 0.31.6 的 Memory.snapshot() 提供 active、cache、peak active（进程启动以来）字节。active 是活跃 MLXArray，cache 是可复用缓冲池，两者合计为 MLX 分配；不包含整个进程/系统的全部内存，peak 不是单请求独占峰值。不改变锁定依赖。
- Protocol 的 DoctorResult/Report 保存稳定检查 ID、状态、原因/建议和已有脱敏 DiagnosticEvent。Client DoctorRunner 组织小型 ordered async checks；本地平台/产物/文件检查由 composition 注入 DoctorCheck，业务资产检查归 ModelLibraryService；托管资产复用 DownloadManager 持有的 CommittedArtifactVerifier，检查磁盘 manifest/索引、身份、摘要与完整目录布局，不更新恢复状态；source IO 归现有 Sources。交互层不复制业务检查，不引入插件框架。
- ServiceFiles 的只读构造不创建目录、不获取写者锁。目录检查分别验证安全所有权/模式和实际读写遍历权限，默认检查不试写。doctor 默认读取已有 discovery 并用现有 authenticated identity 核对实例/版本/数据根，不走 Connection.open 的自动启动。App/worker 的版本和嵌入 fingerprint 一起检查；Metal 资源按 bundle 相对路径检查，不读取开发 PATH。
- 显式扩展检查使用独立服务端 UUID 句柄（最多 4），任务由 Service 拥有；客户端期限/取消通过显式 cancel 请求等待检查停止，取消先到时保留有界 tombstone（256）阻止迟到工作。关闭服务取消并等待这些任务。资源预览、生成准备与显式加载的本地文件检查由 ModelLibraryService 持有 detached 任务（最多 4），避免占用业务 actor；取消传播到检查任务，退出取消并等待它们，使用门闩直到检查结束才释放。取消、busy、shutdown 不映射为未知估算。discovery 在打开前拒绝特殊文件，采用非阻塞打开并再次 fstat 核对类型、身份及权限；不依赖任务组取消去中断系统调用。文件摘要循环可取消、无数据库状态写入；来源检查使用固定 revision 元数据解析，绝不 fetch 权重。部分失败不终止后续检查，异常只记录 allowlisted domain/code 与阶段。未确认停止不会声明已释放。

API 依据：[Apple Dispatch memory pressure](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)、[Apple os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)、[锁定 MLX Memory 源码](https://github.com/ml-explore/mlx-swift/blob/0.31.6/Source/MLX/Memory.swift)。部署目标仍为 macOS 15；该目标不是全版本真机验证证据。
