# KSpeeder 项目安装器与独立发布

## 源码和发布空间

2026-10-26已分别发布两个Linux二进制安装器0.1.0，公开入口和索引已生效，
核心保持0.5.1。真实四站点回读、云端索引安装及保护项审计见
[发布证据](verification/2026-10-26-kspeeder-publish.md)。
原 `https://kspeeder.com/bin/install-kspeeder.sh`、`.ps1`、`install-ks-cli.sh`
及本仓库 legacy 快照保持原字节。两产品同项目构建，源码按用户指定分组：

| 软件标识 | 维护目录 | 公共入口 | 不可变脚本 |
|---|---|---|---|
| ks-cli | kspeeder/ks-cli | binary/ks-cli/ks-cli-install.sh | binary/ks-cli/0.1.0/ks-cli-install.sh |
| kspeeder | kspeeder/kspeeder | binary/kspeeder/kspeeder-install.sh | binary/kspeeder/0.1.0/kspeeder-install.sh |

`kspeeder/lib/binary.sh` 是两个薄适配的共享源；下载、缓存、存储、有界输出、
取消及子进程等待复用既有 zsetup/共享 shell helper。`catalog.json` 仍是
完整维护索引；`release/applications.json` 允许分别生成独立发布候选。
公开包只含生成脚本、索引及已存在的核心，不收集或打包业务二进制。

安装器身份独立于业务版本：脚本0.1.0可读取业务方新的 VERSION/SHA256，
无需为每个产品版本复制安装逻辑。官方URL当前可变，元数据/包切换造成
摘要不匹配时失败保留旧版，重新取得一致发布后再重试；不绕过校验。

## 安装与验收语义

默认用户级二进制落位，可以显式选择持久prefix/staging；不支持system scope，
不自动启动产品、服务、Docker或提权。输出安装信息后退出0。
只执行产品的有界 `version` 命令，首字段须精确等于发布 VERSION。
客户端/服务端各用自己的版本文件和摘要，绝不混用。

Linux三架构有匹配记录；Windows/macOS/OpenWrt不登记到这条裸程序流程。
客户端桌面摘要缺失、桌面原生验证和服务生命周期是后续独立工作。
本地HTTPS/native fixture证明安装协议，不代替ARM设备或服务业务验收。

共享helper新增连字符软件标识与可选精确版本校验，导致旧生成入口字节变化。
因此已有业务候选使用新不可变版本：普通脚本0.1.9、Linkspace0.1.1；
不能以这些文件覆盖已发布FastNet0.1.8/Linkspace0.1.0。
本轮新产品独立发布只包含自己的文件及对应索引记录。

## root@192.168.3.1 的同步与后续更新

2026-10-26通过严格SSH主机密钥检查，只读确认实际Web binary根目录为：

```text
/mnt/sata3-1/istore-data/public_html/binary/
```

该服务器当时Linux stable为0.5.1。连接地址仅为发布操作信息，不写入业务脚本。
新脚本同步到上述各产品公共/不可变目录；产品包仍从KSpeeder业务服务器获取。
不要同步整仓库、lib、tests、README或legacy，不覆盖kspeeder.com的原入口。

先取得当时最新完整配置，再为**一个**软件生成候选：

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes root@192.168.3.1 \
  'cat /mnt/sata3-1/istore-data/public_html/binary/zsetup/config.json' \
  > /ABS/live-config.json
python3 -B scripts/package-app-release.py --application ks-cli \
  --live-config /ABS/live-config.json --zsetup-root /ABS/zsetup-rust \
  --native-cli /ABS/zsetup-linux-x86_64 --output /ABS/ks-cli-review
```

kspeeder同理使用`--application kspeeder`。候选包含完整校验清单、只修改本软件
记录的配置、不可变脚本、公共入口和既有stage/activate/rollback事务。
工具只准备本地候选，不联网或上传。当前输出仍标记`public_release_authorized=false`。

后续获准更新时，把选定候选作为一整个独立目录传到服务器，例如：

```sh
scp -o BatchMode=yes -o StrictHostKeyChecking=yes -r /ABS/ks-cli-review \
  root@192.168.3.1:/mnt/sata3-1/istore-data/ks-cli-review-UNIQUE_ID
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes root@192.168.3.1 \
  'sh /mnt/sata3-1/istore-data/ks-cli-review-UNIQUE_ID/install-app-release.sh stage /mnt/sata3-1/istore-data/ks-cli-review-UNIQUE_ID /mnt/sata3-1/istore-data/public_html/binary'
```

每次使用新的临时发布目录，不覆盖另一份候选。stage只部署不可变脚本并保留
旧指针快照；四站点HTTPS回读SHA/size、隔离真实产品canary和发布授权齐备后，
再使用同一命令把stage改为activate。事务会核对基线配置摘要和核心stable，
拒绝覆盖并发发布或不同字节的不可变版本；rollback恢复旧公共入口及配置。

发布第一个软件后，必须重新获取最新配置，再准备第二个软件。不能把同一旧基线
生成的两个配置连续覆盖到线上。服务器业务服务不会因安装脚本发布而被启动。

修改已发布脚本字节时必须使用新的不可变脚本版本。此次首次暂存后的新路径
曾返回404，文件未修改后再次回读通过；分发/缓存根因未确认，后续仍应等待
四站点实际字节校验通过，不以本地文件存在或等待了固定时长代替。
