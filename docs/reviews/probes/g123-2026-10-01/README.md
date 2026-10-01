# G1–G3 定向复核探针

被测 buildID：mox-m4-7626f190970d727f5fabc613d1ac85eef6e0e4d4f08462fa9f7e59d57537b2a0。

ReviewRestartTests.swift 复用正式 CoreTests 的 fixture/SnapshotTestPersistence。临时加入 Core 测试目标或原样复制 Core/Domain/CoreTests 的隔离包运行；只改变原 G1 测试的恢复动作，将“同进程 resume”换成“关闭并重开、等待恢复”。提交前失败分支通过，已保存后抛错分支的 phase 仍 failed，预期 installed 失败。

ReviewIndependentG123Tests.swift 复用 ServiceTests 的临时模型、真实 HTTP 服务与 committedServiceInstallation。临时加入 Service 测试目标后运行，核验请求已进入慢校验时的服务状态/取消。当前两断言失败：请求未出现在状态中，cancel 返回 notFound。结束主动关闭本测试 manager 释放校验；不访问用户数据。该文件本轮已从正式 Tests 移回这里，不改变项目测试集。

日志位于 .build/review-g123/core.log、service.log、restart.log；可能被清理。修复时正式纳入必要回归，不长期维护重复测试副本。
