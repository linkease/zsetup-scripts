# Linux 安装目录、存储和权限协议

当前开发候选：scripts-0.1.8，要求 Rust zsetup >=0.5.0。M0–M6 已完成，
M7 集成证据见 owning zsetup-rust/docs/2026-10-16-linux-install-storage.md。
这不是发布或生产切换批准。Zig zsetup 保持归档。

## 目录和入口

FastNet 默认用户程序位于 `$HOME/.local/lib/linkease/fastnet/versions/V/bin/fastnet`，
用户命令为 `$HOME/.local/bin/fastnet`。FastPVE 保留 root/PVE 限制，不推定其内部业务操作支持用户模式。
DDNSTO/LinkEase 为系统服务：root 保护程序位于 `/opt/linkease/APP/versions/V/bin/APP`，
current/previous 保留两版；普通调用者的 `$HOME/.local/bin/APP` 是用户所有的受管理链接。
root 不跟随用户 HOME 的链接写系统文件，不覆盖未知旧安装或外来 unit。
原生包安装文件的位置服从包管理器所有权，不能通过 prefix 重定向其 maintainer scripts。

共用前置参数：`--installer-scope user|system`、`--installer-prefix /PATH`、
`--installer-work-dir /PATH`。`--` 结束共用参数，余下逐字交业务；共用参数应在业务参数之前。
环境兼容入口：ZSETUP_INSTALL_SCOPE、ZSETUP_INSTALL_PREFIX、ZSETUP_WORK_DIR。
目录必须为规范绝对路径，支持中文、空格和普通特殊字符。DDNSTO/LinkEase 不支持 user 服务。
DDNSTO_BIN_PATH/LINKEASE_APP_DIR 旧 raw 覆盖变量被拒绝，旧安装需明确迁移，不静默覆盖。

显式 root 的暂存默认 PREFIX/.staging。普通用户准备默认
`$HOME/.local/state/linkease/APP/.staging`，work-dir 参数只选择普通用户准备位置；
root 提交仍用受保护 PREFIX/.staging。两入口：直接业务脚本和 `zsetup install APP --foreground -- ...`
执行相同业务函数，已运行脚本不重复下载自身；`sh -c "$(curl ...)"` 也使用同源内嵌 root 片段。

## 存储与预算

事实来自 canonical runtime-rust 的只读 `zsetup storage PATH --json / get FIELD`。
默认拒绝 tmpfs/ramfs、无法证明持久 backing、只读、所需执行被禁、权限不足、空间不足或零 inode。
overlay 只在当前 namespace 可解析 upperdir 且能证明其挂载介质时给出事实；隐藏路径、循环及异常选项为 unknown。
选择顺序为显式路径、作用域默认目录，不扫描外接盘自动放置。前台终端可重选；无终端退出12，不等待。
原生包目标 `/` 独立检查，换暂存盘不能假称包目标已迁移。

业务服务器 size 不完整，采用获批兼容 B：实测安全上限，而非精确磁盘估计。
FastNet/FastPVE raw32MiB；DDNSTO下载32/展开64MiB/16文件；LinkEase下载128/展开256MiB/128文件。
预算覆盖下载、展开、额外提交/备份复制，增加10%+8MiB；普通用户提权计入两份归档。
算术有 signed32 上限。下载/capture 按32KiB流式限制并持续保留8MiB空间，不整体读安装包。
超限11，空间/文件错误12，参数/不支持/冲突/无提权能力2；业务失败保留原退出码。

只有 zsetup 本体及小型提权引导可用 /tmp；业务包、解压、PM cache/tmp/lists 均使用持久暂存。
成功、失败、取消均由协调器等待 native 子进程清理后释放自身事务；root 服务快照/旧版本按需保留。
SIGKILL/掉电或回滚失败留下锁和恢复目录，后续保守拒绝；人工核对 owner/快照/进程后恢复，不猜PID自动删。

## 提权、取消和缓存

Linux systemd 普通用户仅下载校验归档，不执行业务程序。`sudo -n` 只使用已有凭据；
不足时退出2，提示先 `sudo -v` 或显式 root 调用，不自动请求密码。
可选提权桥需要 sudo、dd、mkfifo、sha256sum 或 openssl；普通 root 安装保持 native SHA，不新增外部摘要依赖。
root 将有界 native/脚本/可选 CA 复制到私有引导目录校验，ready/go 后运行私有副本；
重新取得元数据，导入归档经 native SHA 复验再执行。普通用户数据和参数不作为表达式求值。
自动提权桥的root业务输出并入stderr，stdout控制帧不进入公共JSON/shell协议。
每个协调器只等待自己的子进程。控制 EOF 触发 root TERM、join 和回滚；其结束后才释放普通用户准备。
Rust install 的 POSIX 取消先给业务协调器最多30秒 TERM 回滚，再强制回收剩余进程树；
无响应/强杀留下的锁仍需恢复。generic run/capture 保持原取消协议。

root 所有且不可写的非秘密版本回执允许普通用户读取，故普通用户重复安装也可复用已有版本。
原生 download 给定摘要的缓存可离线复用；业务安装仍刷新版本/SHA 元数据，不宣称完整离线业务安装。
缓存文件必须通过 SHA 或 root 保护的已验证版本回执，不能仅按文件名激活。同版本摘要改变拒绝11。受保护的 .arch 回执同时限制复用架构，架构变化退出2，要求新prefix或明确迁移。

## 支持映射与验证边界

新的 Linux raw 适配首期仅 systemd。SysV 保留 legacy，未移植；不是删除 OpenWrt procd 支持。
DDNSTO OpenWrt opkg/apk 支持 x86_64/aarch64/armv7/mipsel；Lite 在已知内存小于900MB时优先，未知为Standard。
LinkEase OpenWrt 仅 opkg x86_64/aarch64/armv7，APK/MIPS未接入。没有经验证的 deb/rpm 映射，不虚构 apt/yum 包。
OpenWrt 明确 root 调用；Linux systemd 的 sudo 准备桥不推定适用于 OpenWrt。
原生包先验证所有输入，使用持久 .packages 保留当前/前次尝试，独立 .package-lock 防止跨暂存目录并发；/etc/zsetup/install-locks/APP 的小型root租约同时防止跨缓存前缀修改同一系统业务状态。
已有命令必须由 opkg search / apk info 识别本包所有权；不覆盖其他安装方案。
DDNSTO旧配置最多16KiB，先校验保护链及大小，恢复复制由native进程owner等待；超大配置拒绝11。
PM 失败不切 raw 二进制；package-result 记录阶段/退出码，maintainer scripts 不承诺整体回滚。

本地隔离 suites 覆盖真实 HTTPS/native fs/process 和业务/PM stub；真实服务器容器另验证
systemd255 管理器和 UID1000→0 sudo。OpenWrt 宿主仅做只读 storage 探测，不安装真实包、不修改宿主服务。
真实业务公网连接、procd/maintainer scripts、0.5.0 Windows/macOS 原生验收属于后续发布 canary，不能以交叉编译代替。
旧回归覆盖迁移见 2026-10-16-regression-coverage.md；旧 legacy 和未验证入口保持不变。
