# FastPVE 接入验证（2026-10-09）

目标仓库 zsetup-scripts 在 6802d7167ad63d1810724114fa2231e52ccde2ef 的 LinkEase 实现上继续开发；开始时只有用户新加 legacy/fastpve-install.sh 未跟踪。原文件 SHA256 为 5a8babfcfe46c341cde7c35ebda47bafaa19b5b72d95653843e7d595f2445a97，保持原字节，未执行历史安装器。源 ddnsto_all_in_one_script 未改；linkease-tunnel 用户已有 SocksTun-iOS 改动保留。

## 完成结果

- fastpve/ 收拢 business.sh、main.sh、生成的 fastpve-install.sh、README 和隔离测试。共享 bootstrap 原字节未改，两入口都执行 fastpve_install，不重复下载正在执行的安装器。
- catalog/config 为 scripts-0.1.6，总计 50 条记录；新增 fastpve 一条 Debian/apt/x86_64，默认前台。native 仍为 0.2.4，未修改下载器、runtime、Race/DoH/UDP 或配置 schema。
- FastPVE 只检查 root、apt、x86_64、可运行 pveversion，下载/校验/缓存/执行原程序；PVE 安装菜单、配置与虚拟机等业务操作由程序拥有。参数逐项透传、退出码继承，不推断 PVE 大版本或无人值守选项。
- 业务去掉 Bash/awk/sed/curl/wget/外部摘要工具，元数据由 native metadata 读取，新字节由 native download 校验。共享 bootstrap 仍用 curl/wget；私有 marker/size 缓存不重新哈希完整程序，不检测同大小的外部篡改，工作目录不得共享写权限。
- 历史 FastPVE 是 Bash，按 bash -n 验证并固定原摘要；现行所有脚本按 POSIX sh -n 验证。历史快照、产品、业务元数据不进入发布包。

## 测试与优化证据

测试先行提交：8294bc8（双入口/平台/缓存/退出码/发布契约）、550cf0c（修正后台协议夹具）、dc3485c（缓存路径保护）。red.log 证明实现前缺少 canonical installer。首次行为测试在后台输出解析处失败：既有协议为同一行 pid/log/result，测试误按每行一项解析；修正一次后通过，未改 native 协议。

缓存路径红测试发现：mv 的目标如果是指向目录的符号链接，会把 candidate 移到目录内，再以 126 退出。补充普通文件/符号链接检查一次后通过；现在事务清理并保留外部目录，不向重定向路径提交。详情 red-cache-path.log。

最终执行：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup
```

全部通过：模块布局/历史摘要/生成一致性、现行 POSIX 语法、FastNet bootstrap 与真实 zsetup 调用、DDNSTO opkg/apk×四架构和 Linux、LinkEase 安装/回滚，以及统一发布测试。FastPVE 真实 zsetup + 隔离 HTTPS 证明直接/index 两入口、no-cache 元数据、内置 SHA256、参数含空字符串/空格、PVE/root/架构/包管理器拒绝、缓存复用和恢复、版本切换、非法/重复元数据、损坏下载与 version 失败时不启动、旧缓存保留、HTTP 拒绝、final fallback、阶段进度、业务退出码与后台 result、TERM 143 和事务回收。实际 PVE/产品为替身，不改变宿主机服务。双入口 fixture 的 wildcard 平台用于 Ubuntu 主机模拟 PVE；正式索引单独验证精确 Debian/apt/x86_64。

发布测试验证全部记录的路径/size/SHA256、公开/兼容副本一致、历史不可变文件保留、拒绝覆写同版本、确定性重复构建、旧产品清除与发布包没有任何 FastPVE 产品。最终干净源码候选用 package-release.py --require-clean 生成，PACKAGE-SHA256SUMS 和 package-audit.json 记录逐项验证与提交信息。

日志位置：dist/evidence/2026-10-09-fastpve/{red.log,red-cache-path.log,fastpve-test.log,check.log,source-audit.json,product-audit.json,package-audit.json}。

## 四站点只读产品核对

原参考 fw.kspeeder.com 与三 primary/final fallback 的 version.txt 均为 VERSION=0.1.8，FASTPVE_SHA256=0e92cf8ab6ca78cdb2b0125974cbe9d2948181735026f36e6adada0a0fc82486。

通过权威 zsetup 0.2.4 对 dl.istoreos.com、fw.d4ctech.com、fw20.koolcenter.com、fw.koolcenter.com 的 /binary/fastpve/FastPVE-0.1.8 分别执行 HTTPS download --sha256，四次退出 0，字节和摘要一致：9240868 字节，ELF machine 62（x86_64），PT_INTERP=/lib64/ld-linux-x86-64.so.2。程序只放在临时目录供静态头部核对，随后自动删除，没有执行、收集入仓库或打包产品。此检查只证明当时可读取且摘要一致，不替代 PVE 兼容性或以后版本发布验证。

## 仓库与提交

zsetup-scripts 保存测试、实现、原快照、catalog 和发布/AI 文档；本提交包含最终实现与该证据。linkease-tunnel 的 e7dd892 仅更新 zsetup/docs/release.md 的 0.1.6/FastPVE 布局；native .4 发布字节复用既有构建，无重新构建或内核改动。最终 source commit、artifact commit、dirty 状态和候选包摘要见 dist/release/scripts-release-manifest.json 与本地 package-audit.json。

尚未执行真实 PVE 安装/菜单、设备 canary、公网上传或 Git push。部署前仍需指定 PVE 版本/隔离设备及业务方确认的参数与恢复流程。manifest 保持 server-artifacts-and-canary-unverified，线上产物核对不能将状态改成发布或真实安装完成。
