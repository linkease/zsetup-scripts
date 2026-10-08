# 服务器预发布产品模型验证

日期：2026-10-08。用户明确产品包提前放在服务器，本仓库不需要 ddnsto-artifacts。开始时 zsetup-scripts HEAD 为 084021e，工作区干净；源业务仓库仍为 13bfb75，未修改。linkease-tunnel 中既有 SocksTun-iOS 子模块改动保留。

## 实施与边界

- 移除 DDNSTO 产品采集器、维护命令别名、本地产品校验/复制打包及对应采集/产品打包测试；实际业务安装、双入口和发布包验证测试保留。
- package-release.py 不再接受产品目录或采集选项，只组装业务入口、权威 zsetup release 和配置。以 --require-clean 检查源码提交状态，不据本地字节宣称线上产品已经可用。
- 重建候选时仅延续不可变安装脚本/native 历史目录，不从旧候选复制业务包或业务指针。服务器产品及版本/SHA256 元数据仍由业务发布流程提供，安装仍使用 zsetup download 校验。
- 清理本地 dist/ddnsto-artifacts。历史采集摘要和验证记录保留，并明确标注其流程已被替代。无公网上传、真实安装或服务修改。
- FastNet/DDNSTO 业务及生成安装入口没有字节变化，保持脚本 0.1.3 / native 0.2.4，不修改 Race/DNS/HTTPS fallback 规则。

## 验证结果

先提交发布行为测试：原实现的 readiness 断言失败，记录为 /tmp/zsetup-server-red.log；改造后测试通过。覆盖不需要本地产品目录、兼容 URL 字节一致、旧候选产品/指针排除、历史版本保留、配置记录 size/SHA256/路径/平台一致、tar 不含产品、确定性重建、不可变冲突拒绝以及失败暂存回收。

完整检查命令：

```sh
sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup
```

结果：通过 POSIX shell 语法、生成入口检查、模块布局、FastNet bootstrap HTTPS/明确 HTTP 确认与拒绝、FastNet index/参数/缓存/进度、DDNSTO direct/index 与 opkg/apk 四架构/Linux/token/Lite/Standard/缓存/进度/失败回收、统一发布包一致性测试。

前两次原有 FastNet HTTPS fixture 测试在 localhost 下载时超出其 10 秒限制。解析源码显示 hostname 按 DoH/UDP/system 链处理；改用数值 loopback 和动态生成匹配 IP SAN 的测试证书后，FastNet/DDNSTO 聚焦测试及第三次完整检查通过。修改仅在测试 fixture，TLS 校验保持开启，没有增大测试超时或调整产品解析/Race 预算。动态证书生成依赖维护环境已有 OpenSSL，不增加设备依赖。

日志在 dist/evidence/2026-10-08-server-products/，包含 check-attempt-1.log、check-attempt-2.log、最终 check.log 和两业务 loopback 聚焦日志。

本地候选 manifest 标记 business_artifacts.owner=business-server-release、included=false、readiness=server-artifacts-and-canary-unverified。服务器产品、摘要/版本布局、跨站点回读、真实设备 canary 和公网切换不由本地测试代替，当前没有执行公网发布。
