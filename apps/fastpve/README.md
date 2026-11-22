# FastPVE

唯一业务入口为 `fastpve/fastpve-install.sh`。设备已有 zsetup：

```sh
zsetup install fastpve
```

服务器部署完成后，在 PVE 宿主机以 root 执行：

```sh
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/fastpve/fastpve-install.sh)"
```

`wget -qO-` 可替代 curl。首次 bootstrap 使用共享 lib/bootstrap.sh；安装器不重新下载自身。直接入口和 install 都汇合到 fastpve_install，要求 zsetup >=0.2.4。

## 范围与交互

索引声明 Debian / apt / x86_64；业务入口再次检查 x86_64、apt、root，以及存在且能够正常执行的 pveversion。检查只读取系统事实，不调用包管理器，不修改 PVE 服务、源配置、存储或虚拟机。其他 CPU/系统暂不声明支持。

原参考脚本只负责下载和启动 FastPVE，没有提供 PVE 大版本兼容表；这里不推断支持 PVE 7/8/9。真实兼容性和业务修改由 FastPVE 程序负责，上线前在指定 PVE 版本的安全测试设备验证菜单、权限、安装结果与恢复。

默认启动原程序菜单，保持前台和终端。参数逐项原样传给程序，例如 `zsetup install fastpve --foreground -- ARGS...`；不引入安装器自己的菜单选项、不虚构无人值守参数。AI 应先确认 FastPVE 已支持的业务参数；不能将默认菜单当成无交互安装任务。后台只适用于已确认的非交互业务调用，并等待现有 pid/log/result 协议的最终退出码。

退出码：2 平台/PVE 环境/权限或缓存路径不满足；11 元数据缺失/非法/重复；12 元数据文件读取失败；下载、程序 version 和最终程序的非零退出码原样传播；129/130/143 为对应信号退出。启动程序成功不表示已经完成它菜单中的某项 PVE 操作。

## 产品由服务器提前发布

延续 legacy/fastpve-install.sh 的产品协议，站点 `/binary/fastpve/` 提前准备：

```text
version.txt          # VERSION=<VERSION> 与 FASTPVE_SHA256=<64位真实摘要>
FastPVE-<VERSION>     # 不带架构后缀的 x86_64 程序
```

先发布并校验不可变 FastPVE-<VERSION>，最后更新 no-cache 的 version.txt；同版本不得改字节。安装器通过原生 metadata 严格读取两个键，拒绝重复键/路径注入，不 source/eval 元数据。新程序由 zsetup download 内置 SHA256 校验，version 成功后才原子提交缓存，失败保留旧版本。

原参考站点为 https://fw.kspeeder.com/binary/fastpve/；2026-10-09 只读核对的 0.1.8 产物为 ELF x86_64，摘要与元数据一致。新入口仍遵循统一来源组：三个 primary dl.istoreos.com/fw.d4ctech.com/fw20.koolcenter.com，fw.koolcenter.com 最终 fallback。2026-10-09 已通过真实 zsetup 对四站点产品完成只读校验，版本/字节/摘要一致；业务发布流程仍需在后续版本保持这些来源一致；不另建专用下载器、不将旧域名混入共享下载策略。

本仓库发布只包含脚本、zsetup 和完整配置，不包含 FastPVE 产品或业务 version.txt。源码归档不参与发布。

## 缓存与依赖

默认工作目录 `/tmp/zsetup/fastpve`，权限 0700，拒绝缓存目录/文件符号链接和非普通缓存文件，使用私有事务目录，下载/元数据失败或信号退出清理半成品。成功下载和 version 检查后写入 `FastPVE-<VERSION>.verified` 的摘要/大小标记。复用匹配缓存后调用 version，再启动菜单；无标记、大小改变或摘要标记不符时重新下载。历史版本缓存保留，重启后 /tmp 可被清空。

此复用约定与其他业务和 zsetup 产品原则一致，不重复计算已验证私有缓存整个文件的摘要；与 legacy 每次本地重新计算 SHA256 的行为不同。标记不检测同大小的外部内容篡改，因此工作目录只能由安装用户写入；禁止把外部文件手动当作可信缓存或共享给其他用户。ZSETUP_WORK_DIR 只用于工程测试/受控路径。

设备依赖为 POSIX shell、基础 uname/id/mkdir/chmod/mktemp/rm/mv/wc 工具和 PVE 自带 pveversion；直接入口的共享 bootstrap 仍用 curl/wget 读取 stable 或首次取得 zsetup；进入业务逻辑后，以及 zsetup install 入口不依赖它们。业务脚本不依赖 Bash、awk、sed、tr、系统 SHA256 工具、tar/unzip，也不安装额外依赖。原 0.1.8 ELF 要求 /lib64/ld-linux-x86-64.so.2（glibc loader）；其他 ABI/运行库与具体 PVE 版本仍需设备验证。

维护 business.sh/main.sh，运行根目录 scripts/build-entrypoints.py 生成唯一入口。隔离测试：

```sh
python3 -B fastpve/tests/fastpve_test.py /path/to/zsetup/dist/release/zsetup-linux-x86_64
```

测试使用真实 zsetup 与本地 HTTPS，PVE 和业务程序为替身；不改变宿主机服务。正式索引平台匹配由统一发布测试检查，双入口测试中的 wildcard 配置仅服务于 Ubuntu 测试宿主上的模拟 PVE，不是支持声明。
