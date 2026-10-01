# Mox

Mox 是 Apple Silicon macOS 上的本机 MLX 模型工作台。App 可获取、管理和测试模型；同一 worker 提供 CLI，以及按需开启的本机 OpenAI Chat Completions 和 Anthropic Messages 文本接口。

## 源码构建

需要 Apple Silicon Mac、macOS 15 或更新版本、完整 Xcode 及其 Metal Toolchain、Python 3（仅构建脚本使用）。依赖版本锁在 `Package.resolved`。目前真机验收环境是 macOS 27；macOS 15 只是部署目标，尚无真机证据。

```sh
scripts/build-m4.sh Release
open .build/m4/Release/Mox.app
```

CLI 位于 `.build/m4-worker/Release/mox`。App 内嵌同一构建的 worker，不要求用户安装 Python、Homebrew 或独立 CLI。Debug 构建将 `Release` 换为 `Debug`。修改 Swift 源码后请重新运行此脚本；直接在 Xcode 中构建 App 时，嵌入阶段会检查 worker 身份并拒绝使用旧产物。首次 checkout 也先运行此脚本。

## 开始使用

App 默认进入模型页。通过“获取模型…”选择 Hugging Face 或 ModelScope 仓库并先查看精确版本与空间计划，或用“添加本地目录…”引用已有 MLX 模型；本地引用不会复制或删除原文件。安装后在模型详情点击“测试此模型”。下载可在下载页暂停、继续或取消。退出 App 时，自己启动的 worker 有活动下载或生成会提示；外部启动的 worker 不由 App 停止。

CLI 示例（`MODEL_DIR` 指向已有本地 MLX 模型目录）：

```sh
.build/m4-worker/Release/mox models import --alias my-model "$MODEL_DIR"
.build/m4-worker/Release/mox chat --model my-model --prompt '你好' --max-tokens 64
.build/m4-worker/Release/mox models plan --repository mlx-community/Qwen3-0.6B-4bit
.build/m4-worker/Release/mox models pull --repository mlx-community/Qwen3-0.6B-4bit
```

`chat --model` 接受安装 alias 或安装 UUID；`chat --model-path` 只接受本地目录路径。`models list` 列出实际 alias 和 UUID。API 的 `model` 也使用这两种安装标识；模型详情提供可复制的 API 标识。CLI 短操作会连接现有 worker，必要时自启临时 worker；要持续提供 API，可运行 `.build/m4-worker/Release/mox serve`。

App 的模型页可设置全局/单模型生成默认值、查看每项参数的来源，以及固定已安装模型以阻止自动卸载；显式卸载仍可用。CLI 可执行 `mox models sampling --max-tokens 1024` 设置全局值，或 `mox models sampling --temperature 0.2 <安装UUID>` 设置单模型值；`mox models pin <安装UUID>` 与 `mox models pin --off <安装UUID>` 切换固定状态。聊天命令省略参数时继承模型和全局值，stderr 显示实际值及来源。`mox serve --help` 列出当前 worker 生效的默认参数、队列及安全预算启动覆盖；启动覆盖不会写入持久设置。

## 本机 API

公开接口默认关闭。App 的“本机 API”页可开启、复制动态 loopback 地址并显示或重置独立密钥。前台 worker 运行时，CLI 也可执行 `mox api enable`、`mox api status`、`mox api key`。密钥只发给你信任的本机客户端，管理凭据与公开密钥分离。

```sh
curl "$MOX_API_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MOX_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"my-model","messages":[{"role":"user","content":"你好"}]}'
```

将 `MOX_API_URL` 设为页面显示的地址（不带 `/v1`），`MOX_API_KEY` 设为页面显示的密钥。支持 OpenAI Chat Completions 与 Anthropic Messages 的明确子集，包含文本流式、真实 usage 和客户端执行的工具往返；不提供 Responses、embeddings、多模态、LAN 监听或服务端工具执行。结构化工具调用仅对固定 revision、权重及 tokenizer 摘要均经真机验证的受管 `mlx-community/Qwen3-0.6B-4bit` 安装开放；导入目录和其他模型仅支持已验证的文本能力。完整接收/拒绝字段见 [M4 契约](docs/milestones/M4.md)。

数据默认位于 `~/Library/Application Support/Mox/`；模型受管文件、下载暂存、运行索引和测试会话分开存储。App 的服务控件可导出脱敏诊断；下载操作 ID、阶段与安全错误码也可在下载页看到。服务诊断获取失败会明确标记不可取得，并仍导出本机诊断；参数保存失败保留编辑草稿供重试。导出不包含密钥、prompt、完整文件路径或带凭据的 URL。测试模型文件和私有凭据不要提交到仓库。

## 验证与限制

构建后可按 [源码发布收口报告](docs/acceptance/source-release-h12-2026-10-01.md)运行对应规则、存储、HTTP、App 和真实模型验证；报告区分本轮通过、环境阻塞与待人工验收。真实私有镜像和 macOS 15 尚无环境证据。项目不提供已签名或公证的二进制，Homebrew 分发属于后续阶段。

开发者可复跑最终产物检查（真实下载两个小模型，约 650 MiB；须使用未存在的 `.build` 子目录，完成后测试数据保留）：

```sh
python3 -m venv .build/source-release-sdk
.build/source-release-sdk/bin/python -m pip install openai==3.19.2 anthropic==1.8.0
python3 scripts/verify-source-release.py --app .build/m4/Release/Mox.app \
  --data-root .build/source-release-test --sdk-python .build/source-release-sdk/bin/python \
  --evidence .build/source-release-evidence.json
```

测试只启动并停止自身的隔离服务，不读取默认用户数据目录；失败日志和证据位于指定 evidence 的同名旁文件。测试目录中的模型和数据库由开发者核对路径后自行清理，脚本不自动删除。

服务连通后可能仍在校验模型；界面展示校验状态，目标模型通过检查才开始推理。UUID 形式的自定义别名可用，大小写按 UUID 规则解析；与另一安装 ID 冲突的别名会被拒绝。

开发流程见 [CONTRIBUTING](CONTRIBUTING.md)，当前进度见 [HANDOFF](docs/HANDOFF.md)，产品和技术契约分别见 [ARCHITECTURE-DRAFT](ARCHITECTURE-DRAFT.md)与[技术设计](docs/architecture/TECHNICAL-DESIGN.md)。许可证见 [LICENSE](LICENSE)。
