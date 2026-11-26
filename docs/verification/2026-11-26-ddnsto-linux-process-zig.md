# Linux 进程模式低空间 Zig 候选

状态：0.3.5 本地候选，未提交、未部署、无设备或业务服务器变更。
接续 OpenWrt 按包大小预算与 tmpfs 分离；本阶段不改变 systemd、OpenWrt、DSM、华硕和桌面安装策略。

## 已审核产品

2026-11-26 经 HTTPS 从 `https://fw.koolcenter.com/binary/ddnsto/` 下载，只做本地审核。
`ddnsto-zig/VERSION` 内容 `4.2.1`；不能当作 4.2.8 或 4.2.9，也不把 4.2.8 lite 临时 Micro 包当成 Zig。

| 文件 | 字节 | SHA-256 |
|---|---:|---|
| ddnsto-zig/ddnsto.x86_64 | 752664 | 76e21cb89b623ae57ac928380d2fce3c51b502c04a4b58f36bb59ab5cdd3ca5d |
| ddnsto-zig/ddnsto.arm64 | 1483696 | 032e14eae082515f355b2199518b68f506fe7579eb22e58238f48a0bc6fab520 |
| linux-binary/ddnsto-standard-4.2.8.tar.gz | 16757733 | 3bf7ada14448b5aa04afa171e497f85d0b8bb4adcf2209991e52ef5826d4e975 |

标准归档内 x86_64 二进制 4547748 字节，aarch64 二进制 11075768 字节。
裸 Zig ELF 架构分别为 x86-64/AArch64，均静态链接。x86_64 在隔离网络中执行
`-v` 为 4.2.1；`--help`、`example-config` 确认支持 `--config`、`bootConfigPath`、
`logPath` 和 YAML。AArch64 未运行，安装时仍检查真实版本与执行兼容性，不声称真机通过。

## 策略

- 仅无 systemd 的 Linux 用户进程安装器启用；路径仍为 `~/.local/share/ddnsto`。
- 默认 standard，按真实归档、当前架构解包大小和旧二进制备份大小预算，不再为该路径使用固定 184 MiB 上限。
- 空间不足时可选择审核的 Zig。目标版本低于现有安装时明确 E_SPACE，不降级；
  显式 standard、测试业务环境或环境切换也不自动使用未验证的 Zig 能力。
- Zig 原生下载沿用 zsetup 的 HTTPS、SHA-256、精确大小和保留空间控制；不解压、不重编、不关闭校验。
- 可变裸二进制 URL 的字节更换后，旧候选会拒绝 SHA/大小不符；发布者必须审核并更新
  唯一 `platform-releases.json`，再生成安装器。不是设备端盲目信任 VERSION 或自动执行最新字节。
- 版本/摘要仍写入原进程安装凭据；重复执行且无需更新时，不要求再次下载/备份空间。
- 前台启动、PID+启动时间+执行路径识别、停止、回滚沿用原实现；新装 Zig 明确关闭 WebDAV，
  不照搬示例中的默认密码和监听服务。配置及设备身份保留，不增加持久化或守护承诺。

预算使用额外峰值，不抵扣将来会删除的文件：

- standard：`D + E + B + 256 KiB`，再加 10% 向上取整和 8 MiB 保留量。
- Zig：`D + B + 256 KiB`，再加 10% 向上取整和 1 MiB 保留量。
- D 为下载大小，E 为本架构解包大小，B 为当前安装二进制备份大小；新装 B=0。
- x86_64 Zig 新装需要 2164865 字节（约 2.06 MiB）。这是业务安装阶段预算：入口、
  zsetup 自举、已有文件和缓存已占空间，不包含在该新增预算中；也不承诺长期日志无限增长可用。

## 验证

使用 test-driven-development：新增选择/下载测试先失败，再实现；另用真实 Zig 暴露
低空间重复执行失败，补复用分支后通过。

- 产品规划/裸下载测试 7 项：standard 默认、小空间 Zig、新旧版本防降级、未知空间、
  极小空间、测试环境拒绝、裸下载不解压并传入摘要和精确大小。
- 原 Linux 进程套件在真实 zsetup 0.6.4 下 22 项通过（客户端 fixture）。
- 真实 Zig x86_64 离线套件通过：独立网络 namespace，仅 loopback、无路由，非 root
  执行、临时 HOME、假 Token。本地审核二进制替代网络下载边界，实际执行安装配置、
  版本读取、新装、重复执行、降至 1 MiB 可用空间后复用、停止、重启和退出清理。
  未验证真实账号绑定、设备在线或 HTTPS 下载到真实启动的全链路。
- DDNSTO 顶层 206 项，159 通过、47 因可选环境未配置跳过；真实 Zig 项以上述
  独立断网命令另行验证。旧 Bash 4.2/当前 Shell 4 项、产品配置 10 项、固定产品
  路径 6 项、OpenWrt 预算 12 项和临时目录 5 项通过。
- 产品与入口生成检查、公共树、137 条平台记录、diff 检查通过；历史 0.3.4 字节不变。
- 标准检查执行至权限桥接用例时因容器禁止非 root 写 `/proc/self/uid_map` 中止；
  使用 `sudo -n python3 -B tests/privilege_bridge_test.py /tmp/zsetup/rescue/0.6.4/zsetup`
  单独隔离复跑通过。未执行标准脚本中止后的项目，不宣称完整全仓检查通过。

## 待完成

- systemd 路径的 Zig 安装与升级适配。
- AArch64 真机运行及其余路径的低容量文件系统实测。x86_64 进程模式已补充实际
  3 MiB tmpfs 用例，范围见 [服务协议与小容量验证](2026-11-26-ddnsto-zig-service-protocol.md)。
- 新 Zig 版本发布后更新审核元数据；不自动把旧 4.2.8 设备降级。
- 测试服务器部署、真机验收与正式发布，均需另行授权。
