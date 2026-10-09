# LinkEase 接入与验证

日期：2026-10-09。开始时 zsetup-scripts HEAD 为 7f42c39；已有用户未跟踪文件 legacy/install_linkease_linux.sh、legacy/install_linkease_openwrt.sh。对话中第二文件写为 install_llinkease_linux.sh，实际提供的是 OpenWrt 脚本。两个参考文件按原字节纳入归档，来源上游 commit 未知，摘要记录于 legacy/README.md。未修改原 DDNSTO 业务仓库；保留 linkease-tunnel 中已有 SocksTun-iOS 子模块改动。

## 盘点与实现

Linux 参考：固定版本 1.7.5，LinkEase/HEIF converter/media 三程序；另下载 linkmount ZIP 中的 bin 和动态库；tar/unzip、root 写入 /usr/sbin、systemctl/service/init、serviceControl uninstall/install/start。OpenWrt 参考：opkg × x86_64/aarch64/ARM，三主包/UI/语言包；x86_64/aarch64 另外从 iStore 安装 linkmount/remux；无 APK/MIPS。

经现有 native zsetup 只读取得并列出线上 Linux tar 和 amd64 ZIP，确认 tar 根为 linkease-binary-1.7.5/，ZIP 中为 amd64/bin/linkmount_bin 与 bin/lib/*。仅临时检查布局，没有执行程序或将产品存入本仓库，临时文件已回收。

实施模块：linkease/business.sh、main.sh、linkease-install.sh、README.md、tests/linkease_test.py。唯一 APP/APP-install.sh 入口由公共生成器嵌入既有 lib/bootstrap.sh；直接模式 bootstrap 后进入同一业务函数，install mode 使用已有 zsetup/context/source group，不下载自身。

- Native 仍为 0.2.4；没有修改 runtime、Zig 下载器、Race、DoH/UDP、HTTPS 或 HTTP 确认规则。
- 产品全由业务发布流程提前放服务器；沿用原 tar/ZIP/包内容，为它们声明一致版本快照和 SHA256SUMS。新安装脚本不会采集/复制/重新打包产品，也不关闭校验。
- Linux 三架构先全部下载校验、流式取出所需文件、检查 showVersion，再锁住安装目标、备份/停止旧服务、替换文件并按旧 uninstall/install/start 顺序更新服务定义。失败恢复四项产品及旧服务；恢复也失败时保留备份和可行动路径。ZIP 路径非法或重复时拒绝，不直接让归档写入其自定义路径/符号链接。
- OpenWrt 明确仅 opkg × x86_64/aarch64/armv7。全部所需包校验后再交给 opkg，传播安装失败，清理 transaction；不宣称 opkg 部分安装可整体回滚。
- 参数为 --version VERSION / --version=VERSION，LINKEASE_VERSION 提供默认；Linux 默认 1.7.5，OpenWrt 默认服务器 VERSION，无 token/菜单交互。前后台及退出码沿用现有命令协议。
- 统一 catalog 为 scripts-0.1.5：49 条记录（三业务，其中 LinkEase 24 条）。FastNet/DDNSTO 生成入口原字节保持，新版本路径不覆盖旧发布；legacy 不发布。产品路径保留 LinkEase 大写，安装入口为小写 linkease。

## 测试与失败修正

先提交真实 downloader 行为测试，缺入口时失败，记录于 dist/evidence/2026-10-09-linkease/linkease-red.log；补充平台/发布包测试后实施。

第一次直接模式测试的 fixture 禁止了 bootstrap 所需 curl，修正为只允许读取 fixture stable，其他业务下载仍必须使用真实 native zsetup；该测试设置修正没有改变生产网络策略。

复核参考脚本的服务注册语义后，新增“重复 Install 必须先 Uninstall”的服务适配 fixture：旧安装顺序返回 41，并无法重新注册旧服务，记录于 service-upgrade-red.log。一次修正后新流程和回滚都恢复正确卸载/安装顺序，并通过其余故障测试，没有放宽断言或超时。

最终完整命令：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup
```

全部通过：

- POSIX shell 语法（含新增两份归档）、生成脚本一致性、模块/命名规范及七份历史脚本 SHA256。
- 已有 FastNet HTTPS bootstrap/复用/明确 HTTP 确认，以及直接/index 参数、缓存和进度测试；已有 DDNSTO 平台/包管理器/架构/参数/缓存/进度/失败测试。
- LinkEase 使用本地 HTTPS、匹配 IP SAN 的证书和真实 zsetup，业务路径中 awk/sed/curl/wget 陷阱保证依赖精简；直接/index 两入口、运行脚本不下载自身、Linux 三架构、版本参数与非法参数拒绝、四阶段进度、tar/ZIP 缓存复用。
- 缺产品/错 digest/候选程序检查失败均不改现有服务或文件；Linux 旧服务停止失败不替换、服务安装/启动失败恢复旧三程序与整个 linkmount，首次安装失败回收，旧服务恢复失败保留原备份。
- ZIP 越界路径拒绝；OpenWrt opkg 三架构的五/三包选择、全部产品下载在包管理之前、opkg 错误传播；拒绝 APK/MIPS。
- primary 失败后最终 fallback、已有 native detached 协议输出真实 result/log、SIGTERM 143 与 transaction 清理。
- 三业务安装索引/size/SHA256/路径/平台一致、49 条记录、兼容入口同字节、确定性打包、旧/新命名不可变历史保留、冲突拒绝及失败暂存回收，无 legacy/内部源码/产品进入包。

完整日志在 dist/evidence/2026-10-09-linkease/check.log；LinkEase 聚焦日志在 linkease-check.log。服务和包管理操作只使用隔离路径与适配器，没有触碰宿主服务；测试证书生成使用维护环境已有 OpenSSL，不增加设备依赖。

## 发布边界

生成本地 scripts-0.1.5 候选，manifest 的产品所有权仍为 business-server-release / included=false / server-artifacts-and-canary-unverified。LinkEase 产品版本快照、摘要、四站点回读及真实三架构/系统服务 canary 由服务器业务发布流程验证，本地测试不能代替。没有真实安装、公网部署或 Git push。Linux Info-ZIP -Z1/-p 为已记录的安装依赖；SIGKILL/断电保留锁或备份时按模块文档恢复。
