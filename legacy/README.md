# 历史安装脚本

这里保存五份原始源码，用于回顾 FastNet/DDNSTO 的安装经验、调用关系和迁移依据。文件是固定历史快照，不是指向当前 install.sh 的链接；不继续维护，也不加入安装索引或发布包。验收只对这些快照做 POSIX 语法和摘要检查，不执行历史安装逻辑。

来源仓库：`linkease/ddnsto_all_in_one_script`。来源提交：`13bfb7580416487fda17d3d93d72bf6d25eb9800`。归档日期：2026-10-08。五个文件均通过 git show 从该提交原样取得。

| 文件 | 原职责 | SHA256 |
|---|---|---|
| fastnet-install.sh | FastNet 一键安装与 zsetup bootstrap | 21aa238f92e491887e9b7d3e7f2845796891844fce035cf4da4cdb8fe5cbc2a1 |
| install_ddnsto.sh | OpenWrt opkg/apk、Lite/Standard 选择 | 1f137a4f5ec0f76aadbf3d3dbdc8193ec93eb71f095e9110ce3881d5ef3e7707 |
| install_ddnsto_business.sh | 较早的 OpenWrt/zsetup 安装实现 | ddcb69decce88ba6544b268c3bb2f8d8adde533f9c197479932bd46a99d4deeb |
| install_ddnsto_linux.sh | Linux 两架构安装 | 0dbb19088fd4aae18c597c8f5455eaf28b4ef3bbd5adac7f551b85077c572c86 |
| setup_ddnsto.sh | 旧入口调用、token 配置和状态检查 | 53b69f9d7a6d287405c6ba88fb891f78ab362cdbb964dbf73c62d0bc83a8ff52 |

当前维护和调用入口是 [fastnet/install.sh](../fastnet/install.sh)、[ddnsto/install.sh](../ddnsto/install.sh)，也可使用 zsetup install fastnet/ddnsto。下载协议、校验与依赖以这些现行入口为准，历史脚本保留当时的实现。

原业务仓库与线上旧 URL 保留；线上兼容入口由当前 DDNSTO 安装脚本生成，同名快照不参与生成。详见 [发布流程](../docs/release.md)。
