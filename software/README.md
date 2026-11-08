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
