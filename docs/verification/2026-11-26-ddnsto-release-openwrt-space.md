# DDNSTO 0.3.4 OpenWrt 空间预算修复候选

状态：测试地址已部署并回读校验，待用户真机反馈。不是正式发布。

## 范围与授权

- 用户报告 ImmortalWrt 25.12.2 / mediatek/filogic / aarch64 / APK 全新安装失败。
  根分区可用约 165.4 MiB，/tmp 可用 234.6 MiB；无 DDNSTO 包、配置、服务或 /opt。
  诊断只有 checking → installing → exit_code=12。固件没有 stat，df 不支持 -i。
- 用户授权修复并发布独立测试地址，真机由用户运行；随后授权提交本次修改，未授权正式发布、推送或设备操作。
- 客户端仍为 4.2.8；包版本、摘要及下载来源不改。安装器新版本 0.3.4，保留 0.3.3 原字节。
- 不修改 zsetup 核心、共享 lib、其他应用、控制台或 ddnsto-static。
- 源分支 main，基线提交 `9b886439717c2c4e0693bd3e06abaa44c95f0b47`；本记录随修复提交，测试与实现分开提交。

## 根因与实现边界

正式 0.3.3 的 SHA-256 为 `31642e21fc07f69d150b7a4a6e683e05d08a055b87ce67be5518fc55dbf2bd49`。
共享政策将 32 MiB 下载上限、64 MiB 解包上限及另一份 64 MiB 解包副本相加，
再加 10% 和 8 MiB，要求 192937984 字节（184 MiB）。用户的空间必然无法通过。
底层 stderr 被默认流程隐藏，未写 reason 文件的失败变成 E_EXECUTOR。

DDNSTO OpenWrt 专用政策保留 32 MiB 下载和 64 MiB 解包上限；原生包管理器直接管理目标文件，
没有 Linux 原始二进制部署的额外完整展开候选。用 32 MiB 包管理器压缩缓存/暂存余量代替该副本，
仍保留 10% 和 8 MiB，要求 156028109 字节（约 148.8 MiB）。这是保守容量预算，
不是动态精确包大小或“所有 149 MiB 设备必定成功”的承诺。依赖包、其他并发写入、
存储探测及真实包安装仍可能失败。已有缓存已经占用的空间反映在可用容量中，不被当作空闲空间。

OpenWrt 准备阶段才安装本应用的政策和诊断回调，共享包事务与其他平台政策不变。
继续检查持久存储、读写/执行权限、归属、inode、锁和摘要；不使用 df/stat 新依赖，不跳过检查。
只把已知存储检查转换为结构化原因，不回显任意子进程输出或 Token。
空间不足明确显示 E_SPACE、路径、需要和可用字节；其他存储异常保留 E_STORAGE。
准备阶段显示 checking，不再仅凭开始准备就声称包恢复已经执行。

## 产品只读核验

未更改产品包。只读下载现有
`https://fw.koolcenter.com/binary/ddnsto/openwrt/lite-apk/4.2.8/ddnsto_aarch64.apk`：
4661994 字节，SHA-256 `aaf16937cad6373849ad1d1f15d64b9a085a55d4f44778c2458997fb2af0b65d`，
与产品配置一致，文件头 ADBd。未执行/重新打包，也未声称完成包内版本或真机验证。

## 验证

- 新增 `tests/ddnsto_openwrt_storage_test.py`，先看到旧实现 6 个失败断言，再实现修复。
  用真实包准备函数与默认流程、模拟 zsetup 只读事实，165 MiB 可进入事务边界；
  16 MiB、未知/内存挂载、零 inode、不安全缓存被拒绝，原因可见且不泄漏 Token。
  事务边界主动停止，绝不修改主机包或服务。共享非 OpenWrt 政策仍为 184 MiB。
- 5 项专项测试通过；DDNSTO 顶层回归 180 项，134 通过、46 因可选原生/旧解释器环境等跳过。
- OpenWrt 生命周期 29 项、共享存储 7 项通过；两阶段生成和 --check、diff 检查通过。
- Shell 兼容 4 项通过，包含本机 sh/Bash 和禁网、只读 bash:4.2 容器的解析及帮助入口。
- 标准 `check.sh --native-bin /tmp/zsetup/rescue/0.6.4/zsetup` 在提权隔离套件中止：
  当前普通用户不能创建 user namespace（unshare /proc/self/uid_map: Operation not permitted）。
  独立 `unshare --user --map-root-user true` 同样失败，相关测试/共享代码无修改。
  此前执行的标准套件通过，不将整个标准检查标为通过，也不把未运行的后续套件当作通过。
- 原生工具 SHA-256 `9e87c8bf447cc14eb1a8d2ebfc5cfc2377bed4fcb99539c9175b644f5f10a237`，
  为既有发布的 zsetup 0.6.4；不编译或修改核心。
- 为补足目标平台检查，使用已允许的 sudo 在测试自建的独立 mount/PID namespace 与 chroot
  运行 `ZSETUP_TEST_APP=ddnsto python3 -B tests/package_storage_test.py <native>`，通过：
  opkg/apk × x86_64/aarch64/armv7/mipsel 映射、真实 HTTPS/存储/下载边界、缓存及临时目录、
  失败处理与清理。包管理器和客户端为 fixture，不执行主机包安装或服务操作，也不等于 ImmortalWrt 真机通过。

## 测试交付与回滚

已发布独立候选 `https://web.toany.net/ddnsto-candidates/20261126-0.3.4-openwrt-space-r1/ddnsto/install.sh`。
使用既有测试打包器和服务器 `/home/ddnsto/installer-candidates/`，临时目录全量 SHA256SUMS 校验后原子激活。
本地候选 `/tmp/ddnsto-test-20261126-034-openwrt-r1`。公网小入口 31324 字节，
SHA-256 `52853291b21553d1872c52bacc30b1a5f03dd6cd66d411486db951b627dd6691`；
完整 Shell 618824 字节，SHA-256 `c352ddf239efe68d7c59edd941f9c2ec9abc8ce696f1320b99f5e1449ceb9541`。
两个入口、两个配置、两个索引、两个完整正文、app.json 和 SHA256SUMS 公网逐字节对照通过；
小入口返回 HTTP 200、UTF-8 text/plain、Cache-Control: no-store。
本机使用隔离缓存从公开小入口执行 `curl | sh -s -- --help`，下载和索引链路成功，退出 0；
未安装客户端、未改动主机服务，该检查不替代用户 OpenWrt 安装验收。
不覆盖正式地址或历史候选。默认连接正式业务，不加 `--env test`。
测试失败请保留终端输出和新 events.log；该地址的发布不等于 ImmortalWrt 真机验收通过。
撤回只涉及此独立候选，不自动降级或删除设备上的客户端/配置。
