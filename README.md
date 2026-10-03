# Mox

Mox 是面向 Apple Silicon 的本地语言模型工作台。原生 macOS App、CLI 和本地 HTTP API 共用同一模型库和 MLX 推理服务。

**当前版本：0.1.0，源码原型。** 本仓库提供源码与本地构建方法，尚未发布签名、公证的安装包；人工体验验收及 macOS 15 真机验证仍待完成。自动测试与独立复核的范围见[验证记录](docs/VALIDATION.md)。

## 功能与限制

- 从 Hugging Face、ModelScope 和配置的镜像规划、下载、校验并安装模型；支持暂停、继续和故障恢复。
- 导入现有本地模型目录，管理模型别名、加载、卸载、固定状态和生成参数。
- 原生聊天界面、流式输出、取消、对话历史与重试分支。
- CLI 及 OpenAI / Anthropic 风格的本地 API；工具调用由客户端执行。
- 只支持已适配的 MLX 文本模型。不是任意权重转换器，也不提供多模态、agent、远程部署或任意 API 字段兼容。

完整支持范围和行为约束见[产品说明](docs/PRODUCT.md)。公共 API 默认关闭，仅监听本机；API 密钥与模型来源凭据分开管理。

## 环境要求

运行目标是 **macOS 15 或更新版本、Apple Silicon**。当前验证机器为 macOS 27，不能据此声称 macOS 15 已验证。内存需求取决于模型大小、上下文及并发请求。

源码构建需要完整 Xcode（Swift **6.3 或更新版本**）、Apple Metal Toolchain、Python 3 与 Git。首轮构建需要联网下载锁定的 Swift 依赖；若 Metal 工具未安装，请在 Xcode 中安装对应组件。Python 仅用于构建和验收脚本，运行 App 不需要 Python。Intel Mac 不在支持范围。

## 从源码构建

检出本仓库后，在仓库根目录运行：

```sh
scripts/build.sh Release
```

该入口构建 CLI、官方 MLX 资源和原生 App，并生成本地运行所需的 ad hoc 签名。它不执行 Developer ID 签名、公证或发布。

产物统一位于：

- App：`.build/Release/Mox.app`
- CLI：`.build/Release/mox`

`.build` 及模型权重、测试数据均不提交到 Git。调试构建使用 `scripts/build.sh Debug`，输出到 `.build/Debug`。版本号的唯一来源是根目录 [VERSION](VERSION)；源码指纹用于检查 App 与 worker 是否匹配。

## 快速开始

```sh
open .build/Release/Mox.app
.build/Release/mox --version
.build/Release/mox --help
```

在 App 中从模型库获取一个适配的 MLX 文本模型，或导入已有本地模型目录，然后进入测试页发送消息。下载较大模型前留出权重、临时下载文件与运行内存所需空间。

CLI 导入已有模型并聊天：

```sh
.build/Release/mox models import /absolute/path/to/model --alias my-model
.build/Release/mox chat --model my-model --prompt '用一句话介绍自己'
```

导入是只读引用，不复制或改写你的模型文件。模型与对话默认存放在用户的 Application Support/Mox 下；自定义数据目录、备份及诊断见[数据说明](docs/DATA.md)。

## 文档与贡献

| 入口 | 内容 |
| --- | --- |
| [产品说明](docs/PRODUCT.md) | 功能、限制、模型和对话行为 |
| [CLI](docs/CLI.md) / [API](docs/API.md) | 命令、协议、鉴权、错误与使用示例 |
| [来源与镜像](docs/SOURCES.md) | 来源配置、凭据、下载与安装 |
| [数据与诊断](docs/DATA.md) | 数据位置、备份、恢复及故障定位 |
| [开发与测试](docs/DEVELOPMENT.md) | 工具链、测试分层、真实模型验证 |
| [架构](docs/ARCHITECTURE.md) | 工程原则、模块职责、生命周期与存储 |
| [验证记录](docs/VALIDATION.md) | 被测版本、证据、人工验收与限制 |
| [贡献指南](CONTRIBUTING.md) | 贡献流程与审查要求 |
| [安全报告](SECURITY.md) | 安全问题报告方式 |
| [第三方声明](THIRD_PARTY.md) / [依赖](docs/DEPENDENCIES.md) | 许可证、固定版本、构建资源 |
| [变更记录](CHANGELOG.md) / [首版发布文案](docs/RELEASE.md) | 首版说明与发布前提 |

Mox 源码采用 [MIT License](LICENSE)。模型和第三方依赖各自的许可证独立适用。
