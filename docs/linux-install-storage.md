# Linux 安装存储：开发中规范

2026-10-16 用户批准实施 M0–M7，Zig 产品归档，仅 Rust zsetup 新增能力。
权威计划与状态在 owning zsetup-rust/docs/2026-10-16-linux-install-storage.md。

当前源码候选已接入FastNet/FastPVE；DDNSTO/LinkEase的systemd适配通过单项自检，
M5整体仍待SysV覆盖范围决定。未公开发布，不改变线上安装行为。
测试：python3 -B tests/install_storage_test.py（隔离挂载事实、PTY及无终端选择）。

* 用户命令推荐 $HOME/.local/bin/ddnsto。版本程序与命令入口分离，系统独立安装
  使用 /opt/linkease/APP。业务必须单独证明用户运行/服务路径兼容，不从可写性推断。
* runtime-rust 负责文件系统事实，Rust zsetup storage 提供稳定查询；业务脚本负责
  目录策略、安装方式、包管理、提权、清理和回滚。不复制下载器或维护 Zig 第二实现。
* installer_layout 是无副作用布局；installer_space_budget 接受下载、展开、额外提交
  副本及额外备份四类已知峰值字节，输出 INSTALLER_REQUIRED_BYTES。旧版本已占用
  空间不能再重复计入，只有额外复制才计入。余量为10%+8MiB，signed32 有界算术。
* installer_preflight 在目标及独立工作目录执行相同峰值预算检查，输出人类计划，
  不创建目录。默认 work root 为 PREFIX/.staging；没有合适位置，前台允许重选，
  非交互错误12退出。临时/最终文件仍须在提交前重检并实施运行时限制。
* 已知内存文件系统、unknown backing、只读、noexec、低空间/无inode按需拒绝。
  不以目录名字代替实际探测，不自动扫描并使用外接盘，不静默回退 /tmp。
* 该存储 helper 不执行sudo/包管理器/服务；独立install-transaction.sh拥有lease、
  原生子进程及清理，install-bounds.sh拥有有实测依据的兼容上限。

用户已选兼容B，9个产物测量见2026-10-16-storage-measurements.json，产品下载仅临时
测量后删除，未执行/重打包。上限：FastNet/FastPVE raw32MiB；DDNSTO下载32/展开64MiB；
LinkEase下载128/展开256MiB/128文件。保留8MiB运行时空间，超限退出11，空间错误12。
缺大小元数据时明确提示，不声称预检充分；业务摘要规则不降级，观察SHA不替代服务器元数据。

FastNet/FastPVE公共前置选项：--installer-scope user|system、--installer-prefix PATH、
--installer-work-dir PATH。--后均传业务原参数；zsetup install的外层--保持不变，例如：

    zsetup install fastnet -- --installer-prefix /data/apps/fastnet -- "业务参数"

程序在PREFIX/versions/VERSION/bin/APP，current指向当前可执行文件，用户入口在
HOME/.local/bin/APP。FastNet默认user，FastPVE仅system且要求root/PVE。保留当前/上一版，
拒绝同版本不同SHA。原cache marker/size复用仅限私有目录，不检测同大小外部篡改。
工程变量ZSETUP_INSTALL_PREFIX/ZSETUP_INSTALL_SCOPE用于隔离fixture；公共选择用上述参数。

先检查空间/挂载，再创建私有事务。已有共享目录不擅自chmod，SIGTERM先等待原生操作
close/join后清理；崩溃遗留lease需人工确认恢复，阻止再次累积，不猜测PID并清理在用文件。
恢复hook失败保留暂存及lease。exec业务菜单前已释放事务；程序自身业务安装目录未迁移。

M0–M4已完成。用户已选A：DDNSTO/LinkEase保留系统服务，程序在root保护的
PREFIX/versions/VERSION/bin（默认/opt/linkease/APP），current/previous保留两版，
命令入口HOME/.local/bin/APP。Linux systemd支持上述公共参数；user scope明确拒绝。
DDNSTO_BIN_PATH/LINKEASE_APP_DIR工程旧覆盖项退休，不能用它们绕过受管理目录。
尚未迁移的OpenWrt分支暂不接受Linux布局参数，M6仍待实施。

系统程序、暂存及祖先必须root所有且组/其他用户不可写，不经过符号链接。
已有旧方案文件/服务、来源不明prefix或命令入口拒绝覆盖；跨暂存目录也共用目标锁。
缓存有受保护文件清单，每个程序/辅助库均重查权限，元数据读取有界。
下载/解压/跨盘提交仍走canonical Rust，有累计上限和8MiB余量。

当前需要显式root执行，例如下载脚本并审阅后运行sudo -H sh SCRIPT；不自动请求密码。
sudo调用者由getent确认，通过runuser降权创建其命令入口，root不写入可由该用户改动的目录。
完整的“普通用户准备、仅提交时跨sudo边界”尚未完成，属于M6；当前方式不算该项通过。
真实sudo/第二UID、旧业务完整回归、真实服务及辅助程序路径为M6/M7后续验收。

业务原生注册退出0仍需核对unit、reload/enable/start及两次is-active。
失败/TERM恢复旧current、unit、启用/运行状态及DDNSTO真实配置
/etc/ddnsto/ddnsto-config.json。恢复失败保留lease与恢复文件，不报成功。
真实DDNSTO从新位置重复注册返回OK但保留旧unit；新适配器只替换已证明归属的旧unit。
unit经真实systemd-analyze验证；root保护的固定.service-run只字面exec已校验路径，
不执行配置表达式。中文、空格、百分号、美元及单双引号路径与真实wrapper执行均已测。
语法依据：[systemd.service](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml)、
[解析实现](https://github.com/systemd/systemd/blob/main/src/core/load-fragment.c)。

服务fixture在私有root/mount/PID namespace中，网络仅本地HTTPS fixture，systemctl及程序为stub。
真实业务程序的独立probe使用隔离网络，未操作宿主服务；这些不等同真实systemd业务健康。
详细证据见2026-10-16-service-storage-evidence.json及三个service probe JSON。
M5新待决：SysV真实生成的脚本无.service后缀、空格拆词有误，foreground owner还会回收
其直接派生的daemon。首期仅交付systemd并保留SysV legacy，或本轮同时迁移SysV监督协议，
待用户决定；在此之前新适配器对非systemd拒绝，旧入口及legacy参考保留。M6/M7未开始。

这不是新版本发布或生产安装证据；线上0.4.0缺新增storage/capture及下载限制参数，
新脚本必须随未来具备这些能力的原生版本/最低版本配置一起发布，不能提前替换线上脚本。
