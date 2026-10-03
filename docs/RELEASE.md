# 首版源码发布准备

## 可用于 GitHub Release 的文案

Mox 0.1.0 是面向 Apple Silicon 的本地语言模型工作台源码原型，提供原生 macOS App、CLI，以及共用模型库的本地 MLX 推理服务。

支持 Hugging Face / ModelScope 来源与镜像、可恢复下载和安装、只读导入本地模型、流式聊天及取消、对话历史，以及 OpenAI / Anthropic 风格的本机 API。详细协议与限制请以 README 和正式文档为准。

本版只发布源码；不提供签名、公证的安装包，不含模型权重。运行目标 macOS 15+，Apple Silicon；源码构建需要 Swift 6.3+、完整 Xcode 和 Metal Toolchain。macOS 15 部署目标尚未真机验证。真实 MLX、自动测试、独立复核和人工验收的实际范围见验证记录，不能把规则测试或 CI 当作 GPU 验证。

## 授权后的操作步骤

主分支推送会触发仓库检查；推送成功不等于创建了标签或 Release。

1. 独立复核最终源码、文档、提交清单和 [验证记录](VALIDATION.md)，处理必需缺陷；用户完成体验验收并决定是否接受记录中的验证限制。
2. 核对 `VERSION` 为 `0.1.0`，工作树干净，确认 main 的最新变化；有开发分支时合并到 main，必要时重新构建和定向测试合并结果。
3. 用户授权后推送 main；查看 GitHub 自动检查真实结果，不因本地通过假定远端通过。
4. 明确授权后在被审查的 main 提交创建 `v0.1.0` 标签并推送。根据本节文案和实际验证结果创建源码 Release；不附带本地 App、CLI、权重、测试数据库或私有材料。
5. 确认源码包与文档可访问后，另行获得授权再删除远端开发分支。不要改写历史。

## 构建与分发

当前 `.github/workflows/check.yml` 只执行检查，不构建分发包，不自动创建 Release。

首版采用源码 Release：确认目标提交的检查结果后，按授权创建版本标签及 GitHub Release。GitHub 自动提供标签对应源码的 ZIP 和 tar.gz，不需要额外编译工作流。Release 正文应说明构建条件、功能范围和未验证项。

以后提供二进制时，再增加独立发布工作流：在具备所需 Xcode 和 Metal 工具链的 Apple Silicon 环境中运行 `scripts/build.sh`，验证 App、CLI 与资源完整性，完成签名、公证并上传分发包。签名凭据放在受控的 Actions secrets 中；普通检查工作流不持有发布凭据。二进制发布不属于 0.1.0 源码发布范围。
