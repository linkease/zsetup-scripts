# DDNSTO 0.2.3 本地候选：上线缺口修复

状态：本地候选，未提交、推送或部署；不代表全平台上线验收通过。
测试站仍保持 0.2.2，正式控制台开关和线上安装器均未修改。
本轮不修改或编译 zsetup 核心源码，仅复用已发布的 0.5.0 Linux x86_64。

## 本轮变更

- Linux 管理命令复用首次安装的已校验缓存；离线查找不下载、不创建缓存目录。
  显式 `ZSETUP_BIN`、缓存和 PATH 中的程序都须通过现有摘要、权限和祖先路径校验，
  不能先执行 `--version` 再把程序认定为可信。无可用缓存时失败并给出提示。
- 锁测试迁移到当前 `ddnsto_machine_locked`，在临时目录测试竞争、已有锁、符号链接、
  失败和信号清理；不为生产实现增加可绕过全局锁的路径环境变量。
- 发布检查使用 `ddnsto/ddnsto-install.sh`，同时校验规范入口、兼容入口和 PowerShell。
  不再要求旧的 4.2.3 包、VERSION 或运行时不依赖的 SHA256SUMS 旁路文件。
- `--verify-products` 流式校验已审核清单内的 Linux/macOS/Windows/OpenWrt/SPK
  安装包 SHA256 和大小，不落盘、不安装。清单摘要须仍存在于当前维护的安装脚本中。
  这是清单范围内的安装包校验，不覆盖 Docker 镜像、QNAP 手工包或真机生命周期。
- 默认仅检查入口时，`publication_inputs_ready=false`；即使入口和包都通过，
  `device_canary=not_checked` 也不会改变。此工具不能单独批准正式上线。
- 安装器候选升为 0.2.3，保持已发布/测试中的 0.2.2 不可变；其他应用版本路径不变。

## 复现命令

```sh
python3 -B scripts/build-entrypoints.py --check
python3 -B tests/publication_test.py
python3 -B tests/ddnsto_offline_native_test.py
python3 -B ddnsto/tests/operation_lock_test.py
DDNSTO_TEST_NATIVE=/path/to/verified/zsetup python3 -B tests/ddnsto_managed_cli_test.py
sh scripts/check.sh --native-bin /path/to/verified/zsetup

# 只读公网核验，会下载清单内所有安装包的数据以计算摘要，不执行安装。
python3 -B scripts/check-publication.py --mode direct --verify-products
```

`direct` 不要求 zsetup 公共索引已有 DDNSTO 记录；仍要求候选版本的规范入口、
兼容入口和 Windows 入口均已发布。若只部署了测试站专用 install.sh/install.ps1，
不能拿该临时布局冒充 CDN 正式发布通过。

## 本次公网回读和候选打包

`https://fw.koolcenter.com/binary` 的 direct + verify-products 检查：

- 清单内 27 个客户端安装包全部完整读取并通过 SHA256/size 校验。
- `ddnsto/ddnsto-install.sh`、`ddnsto/install.sh`、`ddnsto/install.ps1`，以及
  `ddnsto/0.2.3/` 下对应三个入口均返回 404。
- 因此 `product_bytes=verified`，但 `entrypoints_ready=false`、
  `publication_inputs_ready=false`、`device_canary=not_checked`；检查器按预期退出 1。
- 本地生成 `dist/ddnsto-entrypoints-0.2.3-readiness-20261109/`，含入口、规则、manifest
  和 SHA256SUMS；不含 native 或客户端安装包，未上传。
- 候选 7 个发布文件的 `sha256sum -c SHA256SUMS` 全部通过。Shell 入口 SHA256：
  `7eeb776302ef326093f844db539a719bc1eee80aa8dd1ca1bc0bc4feb8fabbff`。

## 本地验证

- 发布检查 9 项、离线 native 查找 4 项、锁竞争 5 项、native-only 驱动 3 项通过。
- 当前 managed CLI 24 项通过（使用真实已发布 native，无跳过）。
- OpenWrt 生命周期 29 项、适配 5 项通过（隔离包管理器 fixture，不是真机）。
- bootstrap 策略 17 项、产品 pin 6 项通过（提供真实 native，无跳过）。
- 入口集成 2 项、附加平台适配 4 项、入口打包 1 项、桌面候选隔离 1 项通过。
- 生成物一致性、模块布局和 `git diff --check` 通过。
- Linux 隔离容器需 Python 与 jq。首次运行暴露硬编码 Python 路径和缺少 jq：
  测试替身现使用 `sys.executable`；jq 必须由隔离测试环境提供，不能把缺依赖当作产品成功。
- 补齐依赖后，断网、运行结束自动移除的 `python:3.12.11-slim` 容器中，
  当前 managed lifecycle 18 项全部通过，离线 native 查找 4 项全部通过。
  使用真实已发布 zsetup 0.5.0，systemctl 为隔离替身；不等于真实 systemd 或设备验收。
- 全仓 `check.sh --native-bin` 已执行：布局、storage、受限解包、事务、launcher 等通过后，
  在 privilege bridge 的 user namespace 创建处因 `/proc/self/uid_map: Operation not permitted`
  中止，不能报告全仓通过。
- 旧 `cross_platform_installer_test.py`：锁套件已通过；下一套
  `service_management_test.py` 15 项中 12 项失败，原因包括旧 harness 未加载
  `installer_dispatch`。后续套件尚未由这个 fail-fast 入口执行，禁止宣称完整回归通过。

## 正式上线前仍需完成

1. 迁移剩余旧跨平台回归，保留原安全断言与明确的替代覆盖关系；补跑隔离权限测试。
2. Linux `/tmp` 缓存被清理或重启丢失后的管理能力仍需持久化/恢复方案验收；本轮只修复
   “已有安全缓存却找不到”的问题，不承诺无缓存离线管理。
3. Docker 自动发现后的交互选择尚未接入主入口，镜像和设备身份升级验收另列。
4. 拟正式支持的平台逐个完成首次安装、升级、启停、设备重启、卸载和控制台在线闭环。
5. 正式独立发布配置、不可变路径回读、回退预案和生产构建开关需单独验收和授权。
