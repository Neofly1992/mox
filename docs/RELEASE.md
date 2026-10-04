# 二进制 Draft Release 与人工发布

Mox 0.1.0 是 Apple Silicon 源码原型。发布工作流提供完整 App ZIP，明确为 **ad hoc 签名、未公证的实验包**；没有 Developer ID 身份，不是正式签名安装包，不含模型。macOS 15 是部署目标，尚无 macOS 15 真机验收结论。

## 工作流与权限

- `Repository checks` 保留普通仓库/规则检查，不获取发布权限。
- `Binary build verification` 在开发分支 `codex/release-binaries` 推送或手动触发，使用只读 token，不需要标签或发布 secrets，不创建 Release。其 Actions artifact 保留 14 天，用于验证构建链路；不等同于最终 Release 附件验收。
- `Draft binary release` 只允许从默认分支手动触发，输入已存在的 `vVERSION` 标签，并明确勾选接受 ad hoc 未公证包。先构建，再上传至 Draft prerelease；永不自动公开。
- 两条二进制入口共用 `build-binary.yml`，调用 `scripts/build.sh Release` 和现有仓库检查入口。构建任务没有发布凭据。完整 Xcode 26.6、Swift 6.3+ 与 Metal compiler 均在 `macos-26` ARM64 runner 实际检查；缺 Metal 时按 Apple 官方方法安装组件，失败即终止，不转为规则测试成功。
- 仅上传任务使用 GitHub 自动生成、限当前仓库和任务生命周期的 `GITHUB_TOKEN`，授予 `contents: write`；构建和普通 CI 仍只读。不需要 PAT 或自建发布 secret。Contents 写权限也包含标签/源码写权限，不能声称平台提供仅 Release 写权限；脚本只使用 Release 创建/附件上传 API，不写 Git ref。
- 上传任务绑定 `binary-release` environment。建议限制到默认分支并设置 required reviewer；这些保护须在仓库设置中实际配置，YAML 声明 environment 本身不等于已有审批保护。配置须另行授权。PR 不调用发布工作流。

GitHub 手动工作流要先存在于默认分支；开发阶段通过上述分支 push 验证，无需为此提前合并、创建标签或 Release。

## 获得相应授权后的操作

提交、推送开发分支、合并 main、创建标签、创建 Draft、公开发布是独立动作，分别获得用户授权。

1. 审查源码与工作流、远端完整构建结果和验证边界；批准后合并默认分支，检查合并提交。必要时先手动运行 `Binary build verification`。
2. 确认 `VERSION` 与预期版本一致，在审查过的提交创建并推送 `v0.1.0`（版本变化时以 VERSION 为准）。工作流不创建、移动或替换标签。
3. 用户批准后配置 environment 保护；运行 `Draft binary release`，选择默认分支，填写精确标签并勾选 ad hoc 确认。checkout 使用完整 `refs/tags/...`，HEAD 必须等于标签 commit，标签必须精确等于 `v` + VERSION；锁文件/源码身份变化时失败。
4. 查看成功运行和 Draft 的附件。上传前再次确认远端标签 commit。现有公开 Release 或没有匹配 commit/signing 标记的 Draft 一律拒绝，不修改正文、删除或覆盖附件。构建 artifact 也按 run ID/attempt 唯一命名，上传任务按成功构建返回的不可变 artifact ID 下载；只重跑失败的上传任务时仍使用原构建，重跑全部时获得新构建。仅重跑上传可续传未上传的附件，已存在且 GitHub SHA-256 digest/大小一致的附件跳过。若 502 留下 `starter` 空附件，或同名附件内容不同/缺少 digest，脚本保留附件并失败；此时必须选择 **Re-run all jobs** 或重新手动触发整个工作流，重新构建产生新 run/attempt 附件名。**Re-run failed jobs** 复用原 artifact，不能解除同名冲突。选择一个完整成功 attempt 的 ZIP、校验文件与 JSON，保留其他附件作为证据。
5. 用户从该 Draft 下载实际附件，按下节在同一份解压产物完成真实 MLX 与 GUI 验收。验收失败继续保留 Draft；需要改代码时用新版本标签，不移动旧标签。
6. 用户记录所验附件名、SHA-256、commit、环境和结果，明确批准后才通过 GitHub UI 手动公开（保留实验包/未公证说明及必要限制）。上传期间禁止手动公开；GitHub 没有将“仍为 Draft”条件与附件上传原子绑定的 API。工作流不代填人工结论，不执行 publish。

每个 ZIP 只有 `Mox.app`，包含嵌入 worker、官方 Metal library、依赖 bundles 和许可证。没有单独发布裸 CLI；CLI 可从 `Mox.app/Contents/Helpers/MoxWorker.app/Contents/MacOS/mox` 使用，必须携带完整 App。SHA-256 文件验证 ZIP，JSON 记录版本、commit、源码身份、签名状态及 run/attempt。仅打包 App，不打包整个 `.build`、权重、用户库、凭据、fixtures、符号或内部过程材料。

## 下载与验收同一份附件

Draft 仅有授权仓库用户可见；公开后普通用户可从 [Releases](https://github.com/Neofly1992/mox/releases) 下载。在下载目录执行（以实际文件名替换）：

```sh
shasum -a 256 -c Mox-v0.1.0-macos-arm64-adhoc-RUN-ATTEMPT.sha256
ditto -x -k Mox-v0.1.0-macos-arm64-adhoc-RUN-ATTEMPT.zip "$HOME/Downloads/Mox acceptance"
"$HOME/Downloads/Mox acceptance/Mox.app/Contents/Helpers/MoxWorker.app/Contents/MacOS/mox" --version
```

校验必须显示 OK；版本、Release 配置、源码 identity 必须与附件 JSON 相同。构建端已经解压同一 ZIP 检查版本、ARM64、签名结构、worker 身份、全部资源与锁定依赖许可证，未运行模型或 GUI。

ad hoc 不提供 Developer ID 信任或公证；下载后的 Gatekeeper 可能阻止启动。如果你确认附件来源、checksum 和风险，可按系统设置中“隐私与安全性”的提示允许该实验 App；不要为此全局关闭 Gatekeeper。系统仍不允许时记录阻塞，不把被拒绝的启动算作验收通过。

真实 MLX 验证使用源码仓库的既有入口，但 `--app` 指向下载解压的 App，不能重新构建替换它：

```sh
python3 scripts/verify-package.py \
  --app "$HOME/Downloads/Mox acceptance/Mox.app" \
  --model /absolute/path/to/isolated-test-model \
  --output .build/release-package-evidence.json
```

测试模型必须预先准备、授权只读引用并记录来源/revision/digest；该入口检查搬迁、离线真实生成、生成结束后的自有进程清理和资源缺失失败。更完整下载/SDK 端到端使用 [DEVELOPMENT](DEVELOPMENT.md) 的 `verify-source-release.py --app` 指向这份 App，在全新隔离根执行。测试失败保留证据，不删除用户模型或个人库。

GUI 验收应在 Terminal 用隔离数据根启动下载 App（该根不应是已有个人库）：

```sh
mkdir -p .build
MOX_DATA_ROOT="$PWD/.build/release-gui-acceptance" \
  "$HOME/Downloads/Mox acceptance/Mox.app/Contents/MacOS/Mox"
```

确认工作台出现；导入测试模型；真实流式生成、停止、再次生成；关闭并重开同一下载 App，检查历史与配置；退出确认自有 worker 停止。保存/网络错误应清晰可恢复。诊断见 [DATA](DATA.md)。记录结果，测试根仅在核对路径、保存所需证据后手动清理。AI 自测或规则通过不能代替这些人工体验结论。

## 正式签名与公证的后续条件

当前路线固定为用户明确选择的 ad hoc 实验包，不自动探测凭据后宣称正式签名。正式分发需要 Apple Developer Program、Developer ID Application 证书与私钥、受限公证凭据。另行授权与实现后，应由内到外签名 worker/App（hardened runtime、timestamp），提交 Apple notarytool、等待 Accepted、staple 并验证 codesign/Gatekeeper，再生成最终 ZIP 和 SHA-256。任何签名、公证或 staple 失败都必须停止正式包上传，不能降级为 ad hoc。

参考：[GitHub runner 架构](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS ARM64 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)、[Apple Xcode 组件安装](https://developer.apple.com/documentation/Xcode/downloading-and-installing-additional-xcode-components)、[Developer ID](https://developer.apple.com/developer-id/)、[公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
