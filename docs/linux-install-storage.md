# Linux 安装存储：开发中规范

2026-10-16 用户批准实施 M0–M7，Zig 产品归档，仅 Rust zsetup 新增能力。
权威计划与状态在 owning zsetup-rust/docs/2026-10-16-linux-install-storage.md。

当前 lib/install-storage.sh 为尚未接入公开入口的共享候选，不改变线上安装行为。
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
* 该 helper 不执行 sudo、包管理器、服务或清理操作；M3–M6尚未接入。

待产品决定：现有版本/SHA元数据不含完整下载/解压大小。严格模式需业务先提供；
兼容模式须按实测上限和流式限制保护，不能声称空间预检充分。决定前保持现行入口。
当前测试只是共享 helper 验证，不是业务安装或新公开版本验收。
