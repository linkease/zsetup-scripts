# Linux 安装存储：开发中规范

2026-10-16 用户批准实施 M0–M7，Zig 产品归档，仅 Rust zsetup 新增能力。
权威计划与状态在 owning zsetup-rust/docs/2026-10-16-linux-install-storage.md。

当前源码候选已接入FastNet/FastPVE，未公开发布，不改变线上安装行为。
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

M0–M4已完成。真实程序namespace服务注册probe证明DDNSTO/LinkEase能生成/opt引用；
systemctl为stub，未验完整真实服务启动。UID1000下LinkEase返回0却报安装服务失败；
DDNSTO返回OK但无unit/控制动作，用户常驻模式未验。M5等待默认系统/用户服务策略决定，
DDNSTO/LinkEase业务函数仍原流程，不支持上述新安装参数，不虚构其迁移完成。
这不是新版本发布或生产安装证据，新脚本必须随未来具备这些能力的原生版本发布。
