# 业务模块与正式服务器目录验证

日期：2026-10-08。起点 zsetup-scripts e241ec2 干净；zsetup/源 DDNSTO 不修改，父仓库已有 SocksTun-iOS 改动保持原状。

## 结果

测试提交 12dcd88、9e05c35；实现提交 `b39fd2fb809c8ae21d224afa6cde24efe15df863`（b39fd2f）。

- fastnet/、ddnsto/ 为唯一业务维护目录，各自拥有 business/main/install、README 和 tests。DDNSTO 另拥有产物采集、验证和兼容 URL 发布规则。
- apps/ 已移除，根目录只保留共享 lib/scripts、统一 catalog、跨业务 tests 和公共 docs。公共 Python 摘要/不可变复制集中在 scripts/release_common.py，不复制到业务模块。
- 五个旧业务文件名链接到模块 install.sh；scripts/collect-ddnsto-artifacts.py 保留为业务采集器的维护命令兼容链接。统一 check/package 的命令入口保留。
- business.sh、main.sh 移动前后逐字节相等。生成 install.sh 只更新维护路径注释，因此脚本版本递增 0.1.3，不覆盖旧 0.1.2；native 复用已验证 0.2.4，无 runtime/网络策略修改。
- 构建器从原有 catalog 读取业务标识，不再维护另一份硬编码业务列表；继续复用权威 zsetup 配置生成器，无新运行时协议。

## 验证证据

`sh scripts/check.sh /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup` 退出 0：模块归属/入口生成、POSIX shell 语法、原 FastNet 两组测试、DDNSTO 双入口与平台/缓存/参数/进度/失败矩阵、公共发布包、DDNSTO 业务包和采集测试全部通过。迁移后的业务测试仍禁用 awk/sed，沿用本地 HTTPS、伪包管理器和隔离安装路径。

独立 module_layout_test/package_test/collect_ddnsto_test 通过；旧采集命令 --help 可用。Python 文件逐个 compile、git diff --check 通过。根目录旧链接均解析到唯一模块入口。测试先指定根业务目录而旧布局失败（缺少 fastnet/business.sh），实现后通过；没有生产失败优化项。

## 正式服务器候选

生产候选生成命令：

```sh
python3 -B scripts/package-release.py \
  --zsetup-root /projects/workspace-linkease-ubuntu/linkease-vpn/linkease-tunnel/zsetup \
  --ddnsto-artifacts dist/ddnsto-artifacts --require-production-ready
```

生成时两源码树干净，readiness 为 `artifacts-verified-canary-required`。复用既有 27 个已验证 DDNSTO 业务产物，不重复公网采集。

- 目录：dist/release/binary/{fastnet,ddnsto,zsetup}/，映射到正式站点 /binary/。
- 索引：config_version scripts-0.1.3，25 条安装记录均指向对应模块的 0.1.3/install.sh，stable/min_version/native artifacts 为 0.2.4。
- 内部 business/main/README/Python/test 文件不存在于 binary 树；网站无需共享 lib 或仓库源码。
- 60 个发布文件逐个核对 manifest size/SHA256，通过；公开入口与生成脚本同字节。
- native 0.2.3/0.2.4 与两业务脚本 0.1.0–0.1.3 均保留不可变文件。
- 传输包：dist/release/zsetup-scripts-scripts-0.1.3.tar.gz，59564372 字节。
- SHA256：`72a9f712a7d23b02307561c6e08989544544b56deb41153d162a2fa917ef5e88`。

目录映射、模块职责、用户入口、FastNet 既有二进制来源、服务器部署顺序/回滚与所需目标信息已写入根 README、模块 README 及 docs/release.md。检查原始日志在 ignored dist/evidence/2026-10-08-modules/check.log。

本次仅整理和生成本地候选；没有连接或上传正式服务器、修改服务、真实业务安装或 Git push。最终目标服务器与发布方式仍按实际部署任务提供。
