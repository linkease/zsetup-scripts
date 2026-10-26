# 2026-10-26 ks-cli 与 KSpeeder 安装器发布

状态：两个Linux安装器0.1.0已公开发布；源代码提交`1e21eef`。
用户在本地实现及候选审阅完成后回复“同意，继续”，本次据此执行分软件发布。
没有部署业务服务、安装SDK或改变核心版本。

## 可用入口

```sh
zsetup install ks-cli --foreground
zsetup install kspeeder --foreground

sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/ks-cli/ks-cli-install.sh)"
sh -c "$(curl -fsSL https://fw.koolcenter.com/binary/kspeeder/kspeeder-install.sh)"
```

这两个入口只部署用户级二进制，默认命令位于`~/.local/bin/`，可使用前置
`--installer-prefix`/`--installer-work-dir`选择持久路径。不自动安装或启动服务。
OpenWrt、Windows和macOS不在本次裸程序安装索引中；已有权威本地zsetup配置
仍优先于云端，旧本地配置需要由其所有者更新。

## 实际执行与验收

- 通过严格SSH连接`root@192.168.3.1`，实际binary根为
  `/mnt/sata3-1/istore-data/public_html/binary/`。
- 发布前保存1271个既有文件的size/mode/mtime及18个关键文件SHA256。
- 每个软件单独打包、暂存不可变脚本、四站点HTTPS回读、隔离真实产品canary、
  激活、固定入口/索引回读和真实云端索引canary。
- 首次暂存时两个产品的8个URL均返回404；检查源站文件、权限和摘要正确，
  未激活。随后同一脚本字节回读全部通过。具体分发/缓存原因未知。
- ks-cli先完成发布；KSpeeder随后重新读取含ks-cli的新配置打包，保留前者记录。
  发布最终状态下再次经云端索引安装ks-cli，确认两产品在最终索引共同可用。
- 两种安装路径实际取得并校验官方0.8.5产品，只执行`version`。安装、缓存复验、
  持久目标、退出状态和暂存清理通过；本地隔离产品目录已清理。
- 最终1270个非配置既有文件元数据一致，18个关键摘要一致；原FastNet/Linkspace
  installer记录、核心`stable_zsetup`和source_groups一致，发布锁已释放。

核心仍为0.5.1；最终索引应用为`fastnet, linkspace, ks-cli, kspeeder`。
最终config.json SHA256：
`b87910d393bf0a3ff1c5b30d50231eff761844271bd36ef0c1dd918ff229512c`。

| 安装器 | 字节数 | SHA256 |
|---|---:|---|
| ks-cli/0.1.0/ks-cli-install.sh | 36385 | 31e1beecb01e7e49ada1291c09aa3f186325e3463cf687b203e958bb679cddac |
| kspeeder/0.1.0/kspeeder-install.sh | 36399 | b1c21c0f321eec6ea94f4e08c6cd890086ba9b608fad7bb5e154f438138f85ed |

四站点为`dl.istoreos.com`、`fw.d4ctech.com`、`fw20.koolcenter.com`和
`fw.koolcenter.com`。逐项URL、摘要、版本、基线和canary结果保存在
[JSON证据](2026-10-26-kspeeder-publish.json)。更早的本地候选证据保持原历史状态。

## 回滚与保留文件

各自发布包保留在服务器的任务目录中，准确路径见JSON的`remote_package`；
调用其中的`install-app-release.sh rollback PACKAGE BINARY_ROOT`即可按快照回退。
若要撤销本次两个软件，必须先回滚KSpeeder，再回滚ks-cli。事务拒绝在后续
其他发布改变配置之后执行乱序回滚，不删除不可变脚本。

当前有效回滚快照为：

```text
kspeeder/.installer-rollback-b87910d393bf0a3ff1c5b30d50231eff761844271bd36ef0c1dd918ff229512c
ks-cli/.installer-rollback-2705702a3c243dcff6a68d29388ca816f976a4296d918e232c78bb7aa7789e5e
```

最初KSpeeder暂存基于旧配置，未激活的暂存快照仍保留用于历史审计；正式发布
使用重新打包的含ks-cli基线和上面列出的新快照。没有实际执行生产回滚。
ARM原生运行、桌面安装、OpenWrt包流程以及加速服务业务验收仍属后续工作。
