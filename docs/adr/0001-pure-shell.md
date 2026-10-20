# ADR-0001：用纯 Shell + 系统工具实现，不引入运行时

- 状态：已接受
- 日期：2026-10-21
- 相关：[architecture.md](../architecture.md)、[deployment.md](../deployment.md)

## 背景

目标环境是两台最小化安装的 Debian 节点，运维希望"一条命令装完"，且不希望在生产 DNS 节点上引入 Python/Go 运行时、容器或编排系统。同时项目需要覆盖安装、部署、巡检、修复、回滚等完整生命周期。

## 决策

全部能力用 Bash + 系统工具实现：`apt` 装依赖、`systemd` 管服务、`keepalived` 做 VIP、`inotifywait` + `rsync` 做同步、`dig`/`netstat`/`ss` 做检查。脚本之间通过命令行参数和环境变量协作，不共享运行时状态。

## 后果

**正面**

- 零运行时依赖，`curl | bash` 即可分发；节点上出问题可以直接 `bash -x` 单步排查。
- 每个脚本可独立执行（`install_dns.sh`、`keepalived_config.sh`、`sync_config.sh`、`verify_deploy.sh`），适合分步排障。
- 与 Debian 生态一致，不需要额外守护进程。

**负面**

- Shell 缺少类型与结构化错误处理，复杂逻辑只能靠 grep/awk 断言；已用 `tests/selftest.sh` 把关键不变量固化成文本断言。
- 重复代码多（每个脚本都有自己的 `log()`、参数解析、root 检查）。
- 生成配置文件靠 heredoc + sed 替换，字段变化时容易与文档漂移，需要 `tests/runtime.sh` 实跑校验。

## 备选方案

| 方案 | 放弃原因 |
| --- | --- |
| Go/Python 单体 Agent | 需要运行时与自更新机制，节点上多一个需要维护的进程 |
| Ansible/Puppet | 引入控制端依赖与学习成本，且仍需自己写 VIP/同步逻辑 |
| Docker Compose 部署 | DNS 需要 host 网络与特权，容器化收益低、故障面更大 |

## 证据

- `install.sh`、`deploy_dns.sh` 等 8 个脚本均只依赖 Debian 基础包。
- `tests/selftest.sh` 用文本断言守护关键不变量；`tests/runtime.sh` 在真实 Debian 12 上验证生成物。
