# FastNet 安装入口跟随 Linux zsetup 0.5.1

2026-10-25 按用户要求更新 runtime-rust → zsetup-rust → zsetup-scripts → FastNet
一键安装链路。正式Linux核心为0.5.1，FastNet业务版本仍为0.7.8，安装脚本仍为0.1.8。

脚本已经动态读取stable和version.txt，因此没有修改其内容，也没有覆盖旧不可变版本。
公开脚本SHA256仍为`cb44ee56ebd967b323737af2ca431e0fbe76f3540a62d2a7259a9a29aa937012`，
大小33259。两个固定入口与fastnet/0.1.8/fastnet-install.sh字节一致。
线上完整Linux索引只登记FastNet，其min_version精确为0.5.1。

本仓库实际修复：scripts/package-release.py接受canonical Linux-only release，调用既有
validate_linux_payload完成完整性校验；canonical配置生成器的对应支持由zsetup-rust维护。
tests/package_test.py新增Linux包不导入Windows/macOS文件或指针的断言。
aggregate输出仍是本地多业务候选，生产继续使用package-app-release.py独立发布FastNet。

FastNet仓库中的cmd/fastnet/fastnet-install.sh已同步为本仓库生成入口，旧独立下载器不再
维护。以后修改business.sh/main.sh/lib中的维护源，运行build-entrypoints.py及check.sh，
再将生成的fastnet/fastnet-install.sh原样复制到FastNet仓库。Docker镜像的内部安装器不属于此入口。

Linux四架构构建、43项Cargo测试、90项原生协议检查、3×21项QEMU检查和5000次资源操作
通过。真实普通用户容器通过公开首次自举、旧0.5.0升级到0.5.1、FastNet0.7.8下载/缓存和
默认持久用户命令检查；没有操作宿主服务。完整脚本fixture套件全部通过，结果在canonical证据目录的
scripts-check-final.log，Linux包回归已覆盖配置、摘要、平台范围与不可变文件。

本次完整73项公开路径回读通过，510项其他业务文件记录和10项受保护SHA保持一致。
发布根为root@192.168.3.1:/mnt/sata3-1/istore-data/public_html/binary。
源目录中已有的三个legacy未跟踪文件未纳入提交或发布，包如实记录scripts_tree_dirty。
其他业务与Windows/macOS指针保持原状态。

核心及FastNet先后发布、回滚顺序和逐项证据见
[canonical发布记录](../../../linkease-vpn/linkease-tunnel/zsetup-rust/docs/2026-10-25-linux-0.5.1-fastnet-publish.md)。
生产回滚应先FastNet入口/索引，再核心指针，保留不可变目录与快照。
