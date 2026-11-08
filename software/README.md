# 软件任务规则

维护源为本目录的 Bash 模块。`task.sh OPERATION REQUEST.json` 在已选目标执行，
`ZSETUP_TASK_TARGET_ID` 必须与请求 targetId 一致；连接和凭据由调用方管理。
运行需要 Bash、完整 jq；首次引导继续使用既有安装器。

协议 software-task/v1：stdout 单个 JSON，进度和原生诊断到 stderr。
退出 0 success，20 needs-ai，21 blocked，22 failed，2 invalid；nativeExitCode
保留实际子程序退出码。查询和计划只读，应用必须绑定计划，不自动启动服务。
未知规则不猜下载地址，不将网络、完整性、权限错误解释成无软件候选。

本模块由 kai-skills 以精确摘要的 owner 资源消费，不新增下载器或 zsetup 核心命令。
已有业务一键入口和公开字节保持原接口，逐项通过适配纳入机器任务。


Docker 静态站点配方：`method: "container"`、`software: "nginx-static"`。
`container` 明确给出 `image`（本模块核验的官方 manifest 摘要）、已有持久
`baseDir`、`dataBytes`、`start: true`。`source` 可选 `official` 或
`linkease-mirror`；镜像站仍使用相同内容摘要，不在失败时偷偷改来源。
计划列出真实 daemon 身份/磁盘、架构、512 MiB 镜像展开与保留预算、数据预算、
普通用户 101:101、只读根及数据卷、独立归属 bridge、健康检查和回退限制。
应用是无状态静态站点；端口在宿主机 127.0.0.1 动态分配，更新可能改变端口。
程序返回实际 endpoint；不据此承诺公网访问或数据库一致性。

仅下载缺失镜像时要求 zsetup0.5+ 的 capture（180 秒、1 MiB 输出上限），
Docker 负责 OCI 摘要校验。计划只读；执行须传入原 `details` 为 `plan`。
更新先启动候选并 HTTP 验证，再切换名称并停止/保留旧实例；健康失败保留旧实例。
`intent: "remove"` 的新计划只删除精确归属的容器和独立网络，保留镜像、配置和数据。
不得将此无状态配方用于数据库迁移；需要数据回退时另走真实备份恢复流程。

模块验收：在已核验的持久文件系统下设置 TMPDIR，并设置
`ZSETUP_TEST_NATIVE=/absolute/verified/zsetup`，执行
`python3 -m unittest discover -s software/tests`；容器进程测试使用真实
zsetup 控制私有假 Docker 子进程。原生 Docker 生命周期证据由消费者保存。
