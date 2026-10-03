# 构建、测试与贡献者入口

## 工具链与产物

Apple Silicon Mac、完整 Xcode、Swift 6.3+（锁定 MLX 所需），构建 App/MLX 另需可运行的 Metal compiler。macOS 15 是部署目标；实际已验证环境为 macOS 27 / Xcode 27，历史 Xcode 26.6 证据不替代当前构建。运行产物不依赖 Python；开发脚本需要 Python 3。依赖固定在 Package.swift/Package.resolved，不借整理升级。

```sh
scripts/check-toolchain.sh metal
scripts/build.sh Release
open .build/Release/Mox.app
.build/Release/mox --version
```

Debug 将 Release 换为 Debug。最终 CLI/App 位于同一个配置目录，CLI 的 Metal/bundles/许可证一起携带；App 内 worker 的资源在 Contents/Helpers/MoxWorker.app。构建缓存为 `.build/package` 和 `.build/app`，生成 workspace 为 `.build/Mox.xcworkspace`。先 resolve 锁文件，再生成身份并构建 worker/App；直接 Xcode 构建 App 时嵌入检查会拒绝缺失或陈旧 worker。

VERSION 是产品版本唯一来源，生成 CLI 与 App/worker 的版本元数据；build fingerprint 覆盖生产源码、锁文件和构建脚本，协议 wire version 独立。改源码需重新 build；检查 `python3 scripts/stamp-build.py --check`。Debug/Release 指纹相同、配置另列。生成 project 不维护另一份版本数字。

## 自动验证

```sh
python3 scripts/check-repository.py
scripts/test.sh rules
```

rules 运行 Core、Service、Sources 完整 scheme，使用实际 SwiftData、本机 HTTP/socket、进程和 Keychain，昂贵 backend/provider 的测试替身明确标注。不会运行真实 MLX、网络来源集成或 GUI；来源网络测试默认标 skipped。不要用 Xcode filter 选中 0 项的“成功”算通过；检查实际测试数量。沙箱阻止宏插件、构建服务或 loopback 时标环境阻塞。

真实 MLX 显式 opt-in，需要已完整准备、授权引用的本地测试模型，不下载或修改默认用户模型：

```sh
MOX_TEST_MODEL=/absolute/path/to/test-model scripts/test.sh mlx
MOX_TEST_REAL_SOURCES=1 scripts/test.sh rules
```

mlx 使用 Xcode 生成的官方 Metal resources，测试实际流式、取消、再次生成；基准另设置 MOX_BENCHMARK_OUTPUT。来源 opt-in 是远端 metadata/config 验证，不等于完整模型下载。使用公开测试模型并记录 revision/digest；示例 Qwen2.5 见 [DEPENDENCIES](DEPENDENCIES.md)。

App 自动化需登录桌面、允许 UI automation、先构建对应配置和本地 fixture 模型：

```sh
scripts/test.sh ui \
  -only-testing:MoxUITests/MoxUITests/testModelWorkspaceEntry \
  -only-testing:MoxUITests/MoxUITests/testFixtureLongReplyStopRetryAndHistory \
  -only-testing:MoxUITests/MoxUITests/testPublicAPIControls
```

默认 fixture 模型 `.build/test-models/qwen2.5-0.5b-4bit`，可用 MOX_TEST_MODEL 覆盖（某些历史模型名断言需要默认 fixture）。ui 构建当前 Debug MoxTestSupport，测试 Release App；MOX_BUILD_CONFIGURATION=Debug 可选择 Debug。全套 UI 中含真实下载/模型场景，需要其前置资源，不能无条件声称全套通过。

## 真机端到端

```sh
python3 -m venv .build/sdk-venv
.build/sdk-venv/bin/python -m pip install openai==3.19.2 anthropic==1.8.0
.build/sdk-venv/bin/python scripts/verify-source-release.py \
  --app .build/Release/Mox.app --data-root .build/source-test-new \
  --sdk-python .build/sdk-venv/bin/python --evidence .build/source-test.json
```

该入口创建不存在的 `.build` 直属根，真实 HF/MS 下载约 650 MiB、暂停/重开/继续、配置/身份、活动删除保护、SDK 文本/流式/工具/错误。失败保留证据，结束停止自有 worker；测试根由开发者核对路径后清理。

已拥有隔离测试产物可用 `verify-recovery.py --app ... --source-root ... --data-root NEW_ROOT --sdk-python ... --evidence ...` clone 并测恢复、CLI、SDK/重启；不是本轮网络下载证据。`verify-sdk.py` 要求显式 --data-root 与已有 API 服务；绝不默认接入个人库。`verify-runtime.py` 测真实 HTTP/取消阶段及资源统计，`verify-package.py` 测搬迁、离线和资源损坏，`benchmark-history.py` 测有界历史读取；各自 --help 给出参数。不得把性能 fixture 写成真实 GPU 基准。

## CI 范围

GitHub 工作流有跨平台纯仓库检查，以及 macos-26 arm64 / Xcode 26.6 的原生规则测试，运行同一脚本。GitHub 官方 [runner 表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)与 [macos-26 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)已核对架构和 Xcode 路径；规则 scheme 不编译或执行 MLX，不需要 GPU/Metal。标准 hosted macOS 不是本项目真实 MLX/GUI 验证环境。

本地实际脚本执行与远端 Actions 成功是不同证据；检查具体提交对应的实际运行，不能从工作流定义推断“CI 已绿”。真实 MLX/GUI 在有 Metal、登录桌面和测试模型的自有 Mac 显式运行；不假设仓库已配置 self-hosted runner 或私密漏洞入口。

## 二进制构建验证

独立工作流 `Binary build verification` 使用同一 ARM64 runner，实际检查 Swift/Xcode/Metal、调用 `scripts/build.sh Release`，再执行 `python3 scripts/package-release.py`。脚本校验 App/worker 版本、架构、Release 身份、全部依赖 bundles/许可证、ad hoc 签名，并解压最终 ZIP 再验证。它只发布 Actions artifact，无标签、Release 或发布凭据需求。

本地可执行：

```sh
python3 scripts/check-repository.py
scripts/build.sh Release
python3 scripts/package-release.py --output .build/release-check-new
```

输出目录须无同名附件；它只打包 App，不打包 CLI 裸文件或整个构建目录。发布故障/重试安全测试由仓库检查入口调用 `scripts/test-release.py`，使用隔离文件与 GitHub 替身，不写真实 Release。标签 Draft 上传与同一下载附件的真实 MLX/GUI 验收见 [RELEASE](RELEASE.md)。Metal 编译成功不等于 runner 可执行真实 GPU 推理；hosted runner 上不执行这些验收。

## 清理与改动流程

`.build` 是可重建输出与隔离测试数据（含模型/数据库），不提交；不要把清理命令指向 Application Support。Python 缓存、venv、SwiftPM 缓存和个人配置也忽略。删除测试数据前核对路径；它可能含唯一失败证据。

贡献流程见 [CONTRIBUTING](../CONTRIBUTING.md)，验证边界见 [VALIDATION](VALIDATION.md)。依赖许可证和嵌套第三方声明见 [DEPENDENCIES](DEPENDENCIES.md) / [THIRD_PARTY](../THIRD_PARTY.md)。

独立 CLI/TTY 回归使用临时 data root，覆盖管道输入、真实 Ctrl-C、退出信号、Unicode 路径与流式输出：

```sh
python3 scripts/verify-cli.py --binary .build/Release/mox --model /absolute/path/to/test-model
```
