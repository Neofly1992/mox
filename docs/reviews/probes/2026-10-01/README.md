# 治理复核探针

被测生产 buildID：mox-m4-d88127e067682abda153d34763a1ed66ef5c7fe13c4f88d80bea6ac43455fba5。

ReviewCommitTests.swift 使用正式 CoreTests 的 fixture 与 SnapshotTestPersistence；可加入临时测试包（原样复制 Sources/MoxCore、Sources/MoxDomain、Tests/MoxCoreTests）或临时加入正式测试目标。它只令首次安装索引保存失败，后续保存恢复；随后调用 resume，预期应完成索引且不重复获取文件。当前实现仍 failed，下载调用从 4 增至 8，两项断言失败。仅使用 UUID 临时根和假模型，结束清理。

alias_probe.py 在仓库根运行，需要先创建 .build/review-20261001，并有当前 Release App 及 .build/test-models/qwen2.5-0.5b-4bit 测试目录（可替换为自己的测试模型路径）。使用临时根启动自己的 worker，导入只读引用，以 UUID 形状 alias 查询有效参数得到 404，以实际安装 UUID 查询得到 200；不修改原模型，不生成、不输出凭据，结束停止自有 worker并清理临时根。

本轮辅助日志保存在 .build/review-20261001，可能被清理。修复时将关键回归正式纳入测试，不长期维护重复测试副本。
