# KSpeeder 0.9.1 全平台产品镜像

当前候选把两个可信来源合并成一个精确锁：GitHub
`kspeeder/docker_kspeeder v0.9.1` 的 10 个 Linux/OpenWrt 资产，以及
`https://kspeeder.com/bin/` 当前提供的 8 个 macOS/Windows 二进制。每个文件的
名称、字节数和 SHA256 都固定在 `release/kspeeder-products.json`。官网目录只用于
取得锁中的桌面文件；设备安装始终从四个 koolcenter 镜像读取，不直接依赖官网。

没有同步旧的 `kspeeder-installer-*`：官网当前 Shell/PowerShell 安装入口实际先
下载 `ks-cli`，再由 CLI 执行服务安装；这些旧安装器既不是 v0.9.1 GitHub 资产，也
不是标准 apps 二进制安装入口需要的产品。

## 公共布局

已有 `/binary/kspeeder/0.9.1/` 是已发布的 Linux-only 不可变目录，不能补写。
新候选使用发布 ID 作为不可变边界，同时保留旧目录和旧安装器：

```text
/binary/kspeeder/
  releases/RELEASE_ID/       # 不可变；18 个上游文件及本次清单
    release.txt
    release-manifest.json
    SHA256SUMS
  release.txt                # VERSION + RELEASE，最后切换
  version.txt                # 上游元数据，最后切换
  ks-cli-version.txt         # 上游元数据，最后切换
```

`release.txt` 将业务版本 `0.9.1` 与镜像发布 ID 分开，因此同一业务版本可以在不
改写旧不可变目录的前提下补齐平台。低层事务只新增发布目录并原子切换三个根指针；
rollback 恢复指针，历史目录和旧文件始终保留。

## 标准同步与发布

`scripts/release-kspeeder.py` 是唯一维护入口。它读取 GitHub 最新稳定版，验证 10
个 GitHub 资产，逐字节检查 8 个官网桌面资产，并验证官网服务二进制摘要与
`version.txt` 一致。以后同步最新版：

```sh
python3 -B scripts/release-kspeeder.py check --native-bin /ABS/zsetup-linux-x86_64
python3 -B scripts/release-kspeeder.py update-lock
git diff -- release/kspeeder-products.json
```

锁和相关实现必须提交且工作树干净，才可准备、查看计划和发布：

```sh
python3 -B scripts/release-kspeeder.py prepare --native-bin /ABS/zsetup-linux-x86_64
python3 -B scripts/release-kspeeder.py plan --native-bin /ABS/zsetup-linux-x86_64 \
  --server SSH_HOST --binary-root /ABS/WEB_ROOT/binary
python3 -B scripts/release-kspeeder.py publish --native-bin /ABS/zsetup-linux-x86_64 \
  --server SSH_HOST --binary-root /ABS/WEB_ROOT/binary --approve RELEASE_ID
```

发布器先暂存不可变目录，经四个 HTTPS 站点逐字节验证后才切换根指针，再执行服务端
和公网复验。`stage`、`verify-staged`、`activate`、`verify`、`rollback` 可用于分阶段
操作；所有远程变更都要求精确 Release ID。

## apps 安装语义

KS-CLI 与 KSpeeder 安装器 0.1.2 支持：

- Linux：x86_64、aarch64、armv7；
- macOS：Intel、Apple Silicon；
- Windows：x86_64、arm64，PowerShell 5.1 兼容入口。

安装器先读根 `release.txt`，再从 `releases/RELEASE_ID/` 下载 `SHA256SUMS` 和对应
二进制，强制摘要及 `version` 输出一致。它们只做用户级二进制安装，不注册或启动
服务。OpenWrt 继续使用自身包工作流。生成文件、Linux/macOS HTTPS 运行夹具和
Windows 静态合同必须全部通过后，才能发布完整 `apps/`。

官网展示页停在 0.8.2 是网站内容未随 GitHub 产品发布更新；网站源码不在本仓库，
不能通过改下载目录伪装更新展示页。
