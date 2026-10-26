# 2026-10-26 KSpeeder 项目二进制安装验收

范围：`kspeeder/ks-cli`和`kspeeder/kspeeder`的Linux安装器0.1.0；
未来kai-skills可使用相同应用标识、指定持久目录和四字段安装结果。
未发布公网入口或配置、未启动业务服务。原官方脚本和legacy字节未修改。

## 已完成验证

- 测试先行提交`a3b83e3`，先确认两个新入口尚不存在时回归失败，再实现。
- 新增11项真实本地HTTPS/native zsetup回归通过：两个产品、原生安装索引、
  单行bootstrap、不重取自身、精确版本、摘要失败、缓存重验、同版本变更拒绝、
  current/previous、来源与架构映射、未知平台/业务参数拒绝、命令所有权和取消清理。
- 17项独立发布回归通过，覆盖嵌套维护目录与独立公共空间、stage/activate/rollback、
  基线漂移、不可变冲突及其他应用文件保留。所有服务器操作均为本地临时目录fixture。
- 完整`scripts/check.sh`退出0；包含已有FastNet、FastPVE、Linkspace、DDNSTO、
  LinkEase、权限/存储/事务/原生包fixture、生成一致性及完整发布包验证。
- 新增连字符标识最初引入的`tr`依赖被旧最小环境回归发现，已改为shell内建。
  重新执行完整检查通过，未放宽测试环境或断言。
- Linux x86_64隔离目录从官方源真实安装两个0.8.5产品，验证版本和实际SHA256，
  未启动服务；暂存清空、测试安装目录清理完成。最终脚本摘要与canary/候选一致。

完整检查使用已存在的canonical Rust release，无需重新编译：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup-rust \
  /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup-rust/dist/linux-0.5.1-fastnet-20261025/core-package
```

日志保留在`dist/kspeeder-check-20261026-final.log`；其摘要及真实产品/安装器身份
持久化在[JSON证据](2026-10-26-kspeeder-binaries.json)。

## 发布准备与边界

通过严格SSH只读确认服务器binary根目录和Linux stable0.5.1，并取得当时完整配置。
基线只登记FastNet/Linkspace；新产品各生成一份`ready-for-staging`本地候选，
均保留其他应用记录与核心，`public_release_authorized=false`。

源码生成改动影响共享helper的消费者，故候选路径递增到普通脚本0.1.9和
Linkspace0.1.1；现网不可变版本未覆盖。新产品发布只选各自候选，不能上传aggregate包。
同步位置和操作顺序见[安装器发布说明](../kspeeder-installers.md)。

ARM仅完成命名/协议fixture，未声明真机运行通过。Windows/macOS未交付本轮安装器，
ks-cli桌面摘要仍缺；OpenWrt继续走包管理器。服务注册、开机启动、实际网关加速、
四站点新入口回读与生产激活不在本轮完成声明中。
