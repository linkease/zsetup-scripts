# 用户与 AI 调用协议

复用现有 zsetup 命令，未新增服务或网络 RPC。先用 `zsetup context --json` 获取系统事实，`zsetup install --list` 获取配置中的应用标识；列表表示索引声明，不保证当前设备匹配。Product Configuration 中平台匹配由 zsetup 执行，业务脚本再次校验支持范围。

| 标识 | 参数 | 返回与交互 |
|---|---|---|
| fastnet | `zsetup install fastnet --foreground -- ARGS...` | 原样传 ARGS，安装器最终 exec FastNet，退出码继承业务程序；它可能打开菜单，自动化须使用业务已支持的非交互参数，本文不虚构 FastNet 参数 |
| ddnsto | `zsetup install ddnsto --foreground -- --token TOKEN [--force-version lite\|standard] [--verify-status]` | OpenWrt token 可选；Linux 无终端 token 必需。Linux 不支持 lite/verify-status。前台退出码为业务结果 |
| fastpve | 不调用 | 尚无源实现、参数或测试，不在索引中 |

业务入口约定：0 成功；2 参数/平台不支持或缺少必需交互输入；11 业务 metadata 不完整/非法；包管理器、启动程序、zsetup download 的其他错误码原样传播；信号退出 129/130/143。zsetup 自身配置/索引/版本收敛失败通常返回 17；download 的错误类别由其既有命令协议定义，不把一切非零都解释成“业务安装失败”。不要解析人类进度文案作为成功协议。

后台：`zsetup install ddnsto --background -- --token TOKEN` 返回 0 仅表示成功启动，stdout 给出 pid/log/result。等待 result 出现并读取其最终退出码。后台 stdin 关闭，不能回答 token 或 HTTP bootstrap 确认。FastNet 菜单默认使用前台；DDNSTO 默认前台便于直接拿到真实错误。

一键脚本中的 bootstrap 只处理 zsetup 的 HTTPS stable/exact version；直接进入当前脚本的业务函数。安装模式由 zsetup 设置 `ZSETUP_INSTALLER_MODE=1`，提供 ZSETUP_BIN、OS/PACKAGE_MANAGER/ARCH、SOURCE_BASES/SOURCE_FALLBACK、CONFIG_VERSION。AI 正常使用 install，不能伪造这些变量来绕过平台或摘要校验。

zsetup 默认完整本地配置 `/etc/zsetup/config.json` 优先于云端；无本地配置时读云端，故障才使用已验证 last-known-good。配置不按字段合并。SOURCE_GROUP 三个 primary 与 final fallback 顺序保持既有规则。脚本通过 HTTPS 的 VERSION/SHA256SUMS 获取业务发布信息；下载的新包必须由 zsetup 校验 digest。业务缓存复用只信任私有工作目录中已成功校验后写入、与 metadata digest 和文件大小一致的标记；不把该目录用于外部可写内容。

工程测试变量包括 ZSETUP_ROOT/WORK_DIR/BOOTSTRAP_BASES/CA_FILE、DDNSTO_BIN_PATH/SERVICE_PATH/MEM_MB；这些不是面向普通用户的安装参数。token 不写入安装器日志；真实命令行参数和 uci/业务程序如何保存凭据仍遵循业务自身契约。
