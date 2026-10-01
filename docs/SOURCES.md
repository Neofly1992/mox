# 来源、镜像与模型获取

默认来源是 Hugging Face 和 ModelScope。`mox models sources` 列出来源 UUID、协议、origin、默认选择及其来源；`models default-source UUID` 显式选择。GUI 获取页读取同一配置，不由 CLI/API 维护另一份默认值。

在 App 模型工作台打开获取模型与来源连接设置，可编辑来源名称、支持的协议、origin、同协议 mirror 和各自凭据。自定义端点必须实现选定的 HF/MS 协议；任意网页、OCI 或静态 manifest 不是当前支持的来源。mirror 改访问端点，不改 registry/repository/revision 身份。

先计划再获取：显示已解析的精确 revision、文件数、下载与提交峰值空间。CLI 的 `--provider huggingFace|modelScope` 选择相应来源；`--endpoint` 添加/选用同协议 origin，新增端点时必须指定 provider。`--revision` 指定 branch/tag/commit，最终仍解析并固定 revision；默认 HF main / MS master。variant 必须是源内有效布局，不能借路径逃逸。

凭据保存在 macOS Keychain；配置仅保存引用。源和镜像分别授权，不能把源 token 自动发给另一 origin 或跨域重定向。更换凭据先暂存新项，配置保存成功后退休旧项，冲突/失败只清理新项；不能覆盖仍生效的旧凭据。Keychain 不可用会明确失败，不默默改成匿名访问或明文存储。

下载字节写入 Mox 所有的 staging，检查长度、摘要、必要模型资产，再原子安装。分辨内容 SHA、Git blob ID 和 opaque ETag；本地新算摘要不是远端真实性证据。不会改写用户全局 HF cache。任务页面关闭不取消下载；暂停/重启后继续复用已完成文件，失效 partial 可重新下载。

安装/索引保存失败时保留已提交文件；继续与启动恢复核对 manifest 后补全，不重复全量下载。索引存在但任务尚未完成也会重启补全；损坏/冲突明确诊断且不伪造成功。恢复完整性检查在后台，服务探活先可用，模型通过检查才进入推理。

真实私有来源需要正确授权和可用服务。本仓库有 Keychain、跨 origin、配置冲突及故障回归，不将这些替代真实私有镜像验证。提交问题时删除 token、带凭据 URL 和私人仓库名；提供操作 ID、安全错误码和脱敏诊断。
