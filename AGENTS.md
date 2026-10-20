## 仓库速览

DNSHA（SmartDNS-HA）：纯 Shell 实现的 DNS 主备容灾方案。8 个脚本 + 三层测试，节点要求 Debian 13+。

| 入口 | 说明 |
| --- | --- |
| `README.MD` | 三分钟跑起来、脚本一览、验收清单 |
| `docs/README.md` | 文档总入口（按角色选阅读路径） |
| `docs/architecture.md` | 组件、链路、切换时序、端口/文件、**已知限制** |
| `CONTRIBUTING.md` | 改动流程、脚本规范、测试要求、提交信息 |
| `GLOSSARY.md` | 术语表（文档与脚本用词以此为准） |

## 改代码前必须知道

- 参数、路径、服务名以脚本为准；改脚本必须同 PR 更新受影响的 `docs/*.md`。
- 三层测试：`bash tests/selftest.sh`（秒级）→ `tests/runtime.sh`（Debian 容器）→ `tests/docker/run.sh`（双节点漂移）。涉及生成配置/部署/切换的改动至少跑到第二层。
- 关键不变量：`keepalived weight` 绝对值 > 主备 priority 差；AdGuard 上游端口 = SmartDNS 监听端口；`state` 只能是 `MASTER`/`BACKUP`。`tests/selftest.sh` 有断言。
- 不要把未实现的能力写成已实现。已知限制见 `docs/architecture.md#已知限制`。

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues in this repo (`gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage state roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) plus `wayfinder:<type>` labels. See `docs/agents/triage-labels.md`.

### Domain docs

single-context — one root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.
