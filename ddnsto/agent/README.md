# Agent 安装文档发布

`install.md` 是面向 Agent 的唯一安装指南，前端只复制固定链接和账号输入。这里只发布公开 Markdown，不包含账号、SSH 凭据，不修改客户端或安装器。

- 固定路径：当前控制台 HTTPS origin 下的 `/ddnsto-install/agent/install.md`，不写死域名。
- 测试机：`ssh -p 2233 root@tx-nj-02.kooldns.com`
- 服务器目录：`ddns-server` 的 `pyStatic` 下 `ddnsto-install/agent/`，通常为 `/home/ddnsto/shared/ddnsto-static/runtime/py-static/ddnsto-install/agent/`。
- 历史路径：`versions/<文档版本>-<完整SHA256>/install.md`
- 当前指南由 ddns-server 渲染 `https://installer.invalid` 占位 origin，提供 UTF-8 文本与 `Cache-Control: no-store`；Nginx（若存在）仅转发。历史文档保持原字节，不渲染模板，默认 no-store。不要把未渲染模板交给 Agent 执行。

## 发布顺序

1. 修改指南，递增文档版本与末尾标记，核对推荐入口兼容范围。只有文档发布才影响用户，提交源码不自动上线。
2. 审核目标确认、提权、平台分流、失败及验收约束；验证指南命令仅使用官方入口，JSON Token 作为数据传递。
3. 使用 `sha256sum ddnsto/agent/install.md` 获取摘要，在上述服务器目录下创建新历史目录；先传入临时文件，校验摘要后移动到历史路径。历史文件存在时必须比较字节，不覆盖不同内容。
4. 从历史文件复制到同目录临时文件，再用 `mv` 原子切换固定 `install.md`。不要原地重写当前文档，不同步删除历史版本。
5. 用 HTTPS 回读固定链接，验证 200、UTF-8、no-store、无跳转、当前域名和完整末尾标记。固定响应经过 origin 渲染，其摘要不再等于模板摘要；历史模板字节应保持一致。先验证再发布前端。
6. 后续只更新文档时无需部署前端。回滚时从已验证历史文件原子恢复固定文件，重新回读；保留被回滚版本用于追查。兼容的安装器入口不随文档回滚自动回滚。

2026-11-19 起支持各环境同域部署；当前实际更新仅在测试环境，正式环境交由运维。Nginx 默认走官网时需保留到网关的转发规则，不能直接删除所有安装 location。改代理配置前先备份、保留其他路由，`nginx -t` 成功后 reload。

## 验证边界

文档契约及命令参数测试：在仓库根目录执行 `python3 -m unittest discover -s ddnsto/tests -p agent_guide_test.py -v`，使用假 curl，不执行真实安装。

前端单测验证短提示词、Token、复制回退及账号切换。浏览器测试验证链接可读取、缓存头和内容完整性。上述验证不等于真实 Agent 的安装验收，也不建立自动生成远程访问链接的能力。未来可将本指南整理为 skill，但当前不发布 skill 安装入口。

## 2026-11-11 首次测试发布

- 文档 1.0.0 SHA256：`7030f0afaf9b05a065960fe8a8afa76bc4e8ab42754ebeb717391f1ca20d1c7d`。
- 固定与历史链接均为 HTTP 200，UTF-8 text/plain，回读字节一致；固定 no-store，历史 immutable。
- Nginx 已通过 `nginx -t`，原配置备份在 `/etc/nginx/conf.d/web.toany.net.conf.pre-agent-doc-20261111`；保留了线上独立门户路由。
- 没有更改推荐安装脚本、客户端或正式环境。
