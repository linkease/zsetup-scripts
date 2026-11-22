# KSpeeder 项目安装器

KS-CLI 与 KSpeeder 的标准 apps 实现分别位于 `kspeeder/ks-cli` 和
`kspeeder/kspeeder`，共享策略位于 `kspeeder/lib`。Shell 与 PowerShell 自包含入口
由 `scripts/build-entrypoints.py` 生成；`scripts/build.py` 将同字节 payload 复制到
`apps/` 的 0.1.2 不可变目录并生成平台配置和 `SHA256SUMS`。测试代码只位于
`kspeeder/tests` 与 `tests/contracts`，不会进入发布的 `apps/`。

0.1.2 支持普通 Linux、macOS 和 Windows；OpenWrt 继续走包管理工作流。两个入口
都只安装用户级二进制，不安装或启动服务，不执行调用者的业务命令。Linux/macOS
默认命令为 `~/.local/bin/APP`；Windows 默认命令位于
`%LOCALAPPDATA%\KSpeeder\bin\APP.exe`。

产品镜像由 `scripts/release-kspeeder.py` 维护，完整来源、不可变发布 ID 布局、
四站点校验和回滚规则见 [产品镜像合同](kspeeder-product-mirror.md)。产品必须先发布
并通过公网验证，之后才能通过完整 [apps 发布协调器](apps-release.md) 发布安装入口。

历史 0.1.0/0.1.1 入口、旧 `/binary/kspeeder/0.9.1/` 目录和其他官网文件不在此次
事务的删除范围。任何清理都必须作为独立、明确授权的操作进行。
