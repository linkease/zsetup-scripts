# Linkspace 安装模块

唯一维护源为 business.sh、main.sh 与共享 lib；scripts/build-entrypoints.py
生成 linkspace-install.sh。公开入口 /binary/linkspace/linkspace-install.sh，
脚本独立版本 0.1.0。产品版本由 apptunnel 的 linkspace/version.txt 决定，
不跟随其他应用版本。只登记 Linux x86_64/aarch64/armv7，不登记 MIPS 或桌面。
最低 runtime 能力版本 0.5.0；独立打包时 min_version 精确绑定实际 stable。

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/linkspace/linkspace-install.sh)" linkspace version
zsetup install linkspace --foreground -- version
```

默认用户级持久路径 ~/.local/lib/linkease/linkspace/versions/VERSION/bin/linkspace，
命令 ~/.local/bin/linkspace。支持前置 --installer-prefix /持久目录、
--installer-work-dir /持久暂存目录；-- 后业务参数原样传递，退出码原样返回。
不注册服务；用户按产品需要执行 linkspace serve。无业务参数显示产品帮助。
拒绝 system scope、内存文件系统、未知持久性、外部命令覆盖和符号链接管理目录。

版本元数据包含 VERSION、LINKSPACE_{AMD64,ARM64,ARMV7}_SHA256 和对应 _SIZE。
裸程序不可变地址 linkspace/VERSION/linkspace-linux-ARCH；摘要与大小同一文件读取。
复用 canonical zsetup 下载/存储/进程管理；每次缓存复用由 canonical download
重新计算 SHA256，损坏缓存重新下载并恢复执行权限。同版本不同发布摘要拒绝替换。
保留 current 和 previous 两个版本；失败或取消保留旧入口并清理下载及锁。
手动恢复可在没有安装事务时将 current 原子替换为 previous 的链接目标。

回归：python3 -B linkspace/tests/linkspace_test.py /path/to/zsetup-linux-x86_64。
包含真实 HTTPS/native CLI，但产品是 fixture；不能作为 ARM 真实设备验收。
发布只允许本应用入口和 zsetup/config.json；使用实际线上完整配置打包，
stage 后四站点回读，再在隔离容器通过两个入口验证真实产品，最后 activate。
