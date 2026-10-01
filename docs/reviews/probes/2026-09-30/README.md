# 收口复核探针

基线：c6b7b5d 上的未提交收口工作树，buildID a2a2c569cf0a2f690482af2e6f0e4b29a5d7a48b386bc8ad3a241c61a2bba812。

ReviewRaceTests.swift 复用 MoxCoreTests 所依赖的 Core/Domain；可以临时加入测试目标或在原样复制 Core/Domain/CoreTests 的隔离包中运行。它阻塞第一次 downloading 保存，在状态尚未发布时发起第二次 resume，然后放行；正确行为应仅接受一次、仅启动一次传输。本轮两项断言失败。探针不改生产源码，不访问真实模型或网络。

http_probe.py 从仓库根运行，要求已构建 .build/m4/Release/Mox.app。脚本在独立临时根启动自己的 worker，发送带管理鉴权的未完成 body，不输出凭据；结束后停止自己的 worker并删除临时根。日志写入 .build/review-20260930（请先创建该目录）。本轮导入接口 413 正常关闭；下载 Content-Length 超限 413 与不存在模型的 sampling 404 在 3 秒内未关闭，也未返回 Connection: close。不能把该观测写成永久不关闭；当前服务已有 15 秒 idle 策略。

修复时把必要回归纳入正式测试，不长期维护重复测试副本。
