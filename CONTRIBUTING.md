# 贡献指南

感谢你愿意改进 DNSHA。这是一个以 Shell 为主的运维项目，**能跑通、可回滚、可验证**比代码优雅更重要。

## 1. 开始之前

```bash
git clone https://github.com/LarryMKott/SmartDNS-HA.git
cd SmartDNS-HA
bash tests/selftest.sh      # 先确认基线是绿的
```

要求：

- 能读 Bash；了解 `set -euo pipefail`、`trap`、heredoc。
- 有条件的话准备一台 Debian 13 虚拟机或 Docker，用于验证真实行为。
- 提交前读一遍 [docs/architecture.md](docs/architecture.md) 的"已知限制"，避免重复实现已有取舍。

## 2. 仓库结构

```
.
├── install.sh              # 节点初始化（系统/网络/依赖/代码/DDNS）
├── install_dns.sh          # 在节点上安装 SmartDNS + AdGuard
├── keepalived_config.sh    # 生成 VRRP / haproxy / consul 配置
├── sync_config.sh          # 生成配置同步守护与服务
├── deploy_dns.sh           # 控制机侧一键编排
├── verify_deploy.sh        # 单节点 9 项验证
├── health_check.sh         # 双节点巡检（可循环）
├── repair_dns.sh           # 修复与回滚
├── tests/                  # 静态 / 运行态 / 双节点测试
├── docs/                   # 文档（入口 docs/README.md）
├── .github/workflows/      # CI
└── AGENTS.md               # 协作 Agent 约定
```

改脚本时优先复用现有 `log()/echo_error()/echo_warning()` 风格与参数解析方式，不要引入新的日志库或依赖。

## 3. 改动流程

1. **开 issue**（或认领已有 issue）：写清现象、期望、影响面。工作流与标签见 [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md) 与 [docs/agents/triage-labels.md](docs/agents/triage-labels.md)。
2. **写会失败的断言**：能在 `tests/selftest.sh` 里静态断言的，先加断言；需要真实环境的，加到 `tests/runtime.sh`。
3. **改实现**，让断言变绿。
4. **跑测试**：至少 `bash tests/selftest.sh`；涉及部署/keepalived/同步的改动跑 `tests/runtime.sh`；涉及漂移的跑 `tests/docker/run.sh`。
5. **更新文档**：受影响的 `docs/*.md` 必须同 PR 更新；新增取舍写 ADR。
6. **提交 PR**，在描述里贴关键命令与输出。

## 4. 脚本规范

- 每个脚本开头：`#!/bin/bash`、`set -euo pipefail`（或项目内既有等价写法）、统一的日志函数。
- 需要 root 的脚本必须在最前面检查 `EUID`，并给出可执行的提示。
- 参数解析支持 `--help`；非法值必须**退出非 0**，不能静默回退默认值。
- 生成配置文件用 heredoc 时，注意变量展开与转义；生成后尽量用官方校验工具验证（`keepalived -t`、`haproxy -c`、`bash -n`）。
- 不要用 `local` 接命令后直接 `if local x=$(...)` 这类会遮蔽 `$?` 的写法（`tests/selftest.sh` 有断言）。
- 不要覆盖用户既有系统配置：需要改时先备份，命名带时间戳。
- 幂等：重复执行结果一致；删除类操作要有保护（参考同步守护的"空源不删除"）。
- 不打印密码/token；确需输出时提示用户自行查看文件。

## 5. 测试要求

| 改动类型 | 最低要求 |
| --- | --- |
| 文档/注释 | 链接检查（见第 7 节） |
| 单脚本参数/逻辑 | `bash -n` + `tests/selftest.sh` |
| 生成配置（keepalived/haproxy/sync） | 加断言 + `tests/runtime.sh` |
| 部署编排、切换逻辑 | 上述 + `tests/docker/run.sh` |
| 新增依赖 | 同步更新 `install.sh`/`install_dns.sh` 的依赖列表与 `docs/installation.md` |

shellcheck 门禁：`-S error` 与 `-S warning` 必须为零。style 级不阻断，但不要新增明显问题。

## 6. 提交信息

一条提交做一件事。格式：

```
<类型>: <一句话说明>

<为什么改、改了什么、怎么验证的>
```

类型：`feat`、`fix`、`docs`、`test`、`refactor`、`chore`。示例：

```
fix: 同步守护在源目录为空时不得删除对端

rsync --delete 在源为空时会把备节点配置清空。改为先判断目录是否存在且非空，
否则记日志跳过。新增 tests/runtime.sh 第 9 组断言，并在 docs/adr/0003 记录原因。
```

## 7. 文档规范

- 文档入口是 [docs/README.md](docs/README.md)；新增文档必须在那里登记。
- 命令必须可直接复制执行：续行符 `\` 后面不要跟注释。
- 路径、参数、服务名以脚本为准；改脚本时同步改文档。
- 相对链接必须可达。提交前可以粗查：

```bash
# 列出所有 markdown 里的相对链接（人工核对目标是否存在）
grep -rhoE '\]\([^)#][^)]*\)' --include='*.md' . | sed 's/^](//; s/)$//' | sort -u
```

- 术语统一走 [GLOSSARY.md](GLOSSARY.md)。

## 8. 发布

当前仓库没有打 tag，`master` 即发布分支。要做正式发布时：

1. 更新受影响的文档与 `docs/adr/`。
2. 跑全部三层测试。
3. 打 tag（`vX.Y.Z`），在 Release 说明里列出：变更、破坏性变更、升级步骤、已知限制。

## 9. 事故记录

线上事故修复后，在 issue 或 `docs/` 下留一份记录，包含：

```markdown
## 时间线
- HH:MM 发现（怎么发现的）
- HH:MM 止损（做了什么）
- HH:MM 恢复
## 影响
- 影响的客户端/时长/解析失败率
## 根因
- 直接原因 + 为什么会发生（5 Whys）
## 改进项
- [ ] 代码/测试/文档/流程各要改什么（带负责人与期限）
```

只写"已修复"不算事故记录。

## 10. 行为准则

- 对事不对人；review 聚焦事实、可复现证据与影响面。
- 不确定就说不确定，不要用猜测填补空白。
- 不提交无法验证的"应该可以"。

## 相关文档

- 文档索引：[docs/README.md](docs/README.md)
- 架构与限制：[docs/architecture.md](docs/architecture.md)
- 测试细节：[docs/testing.md](docs/testing.md)
