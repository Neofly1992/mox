# CLI

从源码构建后，`mox` 位于 `.build/Release/mox`。下文假设将该目录加入 PATH；不需要全局安装。所有入口的参数以 `mox <命令> --help` 为准。`--version` 分别显示产品版本、源码指纹和构建配置。

## 模型与生成

```sh
mox models import --alias my-model /absolute/path/to/mlx-model
mox models list
mox chat --model my-model --prompt '你好' --max-tokens 64
mox chat --model-path /absolute/path/to/mlx-model --prompt '你好'
mox models plan --repository mlx-community/Qwen3-0.6B-4bit
mox models pull --repository mlx-community/Qwen3-0.6B-4bit
mox models pull --provider modelScope --repository mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

`chat --model` 接受 alias/安装 UUID，`--model-path` 只接受本地目录，二者择一。省略 prompt 时交互多轮输入需要 TTY；Ctrl-C 请求停止并等待。正常回复到 stdout，实际参数来源/统计/错误到 stderr。错误非零退出，参数错误为 2；不解析自由文本回复作为成功判断。

`pull` 和 download resume 等到 installed 才成功退出；暂停、失败或中断明确返回错误。列出的下载 UUID 用于：

```sh
mox models download DOWNLOAD_UUID pause
mox models download DOWNLOAD_UUID resume
mox models download DOWNLOAD_UUID cancel
mox models download DOWNLOAD_UUID discard
```

discard 是显式清理任务/暂存动作，先确认目标 UUID。模型管理动作使用安装 UUID（从 list 获取）：

```sh
mox models show MODEL_UUID
mox models select MODEL_UUID
mox models load MODEL_UUID
mox models unload MODEL_UUID
mox models pin MODEL_UUID
mox models pin --off MODEL_UUID
mox models remove MODEL_UUID
```

select 选择当前版本；不修改不可变快照。remove 对本地导入只移除引用，对托管安装删除其文件；准备/使用中的模型拒绝不安全操作。

## 参数、来源和服务

```sh
mox models sampling --max-tokens 1024
mox models sampling --temperature 0.2 MODEL_UUID
mox models sampling MODEL_UUID
mox models sampling --inherit-temperature MODEL_UUID
mox models sources
mox models default-source REGISTRY_UUID
mox serve --default-max-tokens 256 --queue-capacity 8 --queue-timeout-seconds 60
```

逐字段优先级：请求 > 模型 > worker 启动覆盖 > 持久全局 > 产品默认。继承清除该层显式值，启动 flags 不持久化。serve 内存预算只可压低设备安全建议值；未知或不安全输入拒绝。来源/镜像和凭据配置目前通过 App 的来源连接设置，CLI 不提供通用 config 命令；只读诊断见下方 doctor。来源见 [SOURCES](SOURCES.md)。

短命令连接已有服务，必要时启动并停止自己的临时 worker。`serve` 是持续前台服务，Ctrl-C/SIGTERM 协调退出；已有 root 所有者时明确冲突，不热接管。要使用公开 API，保持服务运行，然后：

```sh
mox api enable
mox api status
mox api key
mox api rotate
mox api disable
```

api 命令不自动启动临时服务。rotate 会让旧 key 失效，key 输出不要放入问题报告或 shell 日志。连接 API 的具体字段见 [API](API.md)。

CLI 的 `--data-root /absolute/path` 选择独立数据根；App 用 `MOX_DATA_ROOT`。同根共享同一服务，不同根有不同索引与凭据身份。常规运行无需 root 或 Python。数据和诊断见 [DATA](DATA.md)。

## 只读诊断

```sh
mox doctor --data-root /absolute/path/to/data
mox doctor --data-root /absolute/path/to/data --json
# 显式耗时/联网检查：服务须已启动，不会自动启动、下载权重或加载模型
mox doctor --data-root /absolute/path/to/data --model MODEL_ALIAS --timeout-seconds 60
mox doctor --data-root /absolute/path/to/data --source-repository owner/model
```

逐项进度写 stderr，`--json` 的结构化报告独占 stdout。退出码：0 表示完成且无失败（警告/跳过仍可存在，应阅读结果），1 表示失败或超时，2 为参数错误，130 为取消。Ctrl-C/SIGTERM 取消当前检查，未运行项目标取消；服务端停止无法确认时结果明确说明。默认每项 15 秒，允许 1–120 秒。无 discovery 的服务检查跳过，本地检查继续，不创建数据根。

`models plan` 与 `models pull` 在下载前显示磁盘峰值与内存评估；`chat` 展示有效参数对应的内存包络。状态推荐/紧张/超预算/未知不代替运行时重新准入；下载不会因为内存风险被禁止。原有磁盘空间检查保留。
