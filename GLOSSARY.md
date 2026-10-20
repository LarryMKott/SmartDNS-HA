# 术语表

本项目文档与脚本里反复出现的词，统一在这里定义。文档之间用词不一致时，以本表为准。

## 架构与容灾

| 术语 | 英文/别名 | 定义 |
| --- | --- | --- |
| 主节点 | master | 部署时指定、默认 `priority 100` 的节点；正常情况下持有 VIP |
| 备节点 | slave / backup | 部署时指定、默认 `priority 90` 的节点；主节点失效时接管 VIP |
| VIP | 虚拟 IP / 浮动 IP | 对外提供 DNS 的地址，同一时刻**只应**落在一台节点上 |
| VRRP | Virtual Router Redundancy Protocol | 用通告与优先级选举决定谁持有 VIP 的协议（IP 协议号 112） |
| 漂移 | failover / 切换 | VIP 从一台节点转移到另一台 |
| 回切 | failback | 原主节点恢复后重新夺回 VIP（默认开启抢占） |
| 抢占 | preempt | 优先级更高的节点恢复后主动夺回 VIP；`nopreempt` 关闭 |
| 脑裂 | split brain | 两节点互相收不到通告，同时认为自己是主，VIP 同时出现 |
| 单播 | unicast | VRRP 点对点通告模式，用于组播不可达的跨网段/云环境 |
| 健康检查 | health check | `check_dns.sh` 对服务与解析的周期性探测，失败会降低优先级 |
| 降权 | weight | 健康检查失败时从 priority 扣减的值（`-20`） |
| 收敛 | convergence | 故障后集群重新达到"只有一台持有 VIP"的稳定状态 |

## 组件

| 术语 | 定义 |
| --- | --- |
| DNSHA / SmartDNS-HA | 本项目名，指整套主备 DNS 方案 |
| SmartDNS | 递归解析与缓存/测速选路组件，默认监听 `:53` |
| AdGuard Home | 过滤与查询日志组件，本项目默认监听 `127.0.0.1:5353`（旁路） |
| Keepalived | VRRP 实现，管理 VIP 与健康检查 |
| Haproxy | 可选模式下的 TCP 负载均衡器，独占 `:53` |
| Consul | 可选模式下的服务注册发现组件，不接管 VIP |
| 控制机 | 执行部署/巡检/修复的运维主机，通过 SSH 操作节点，不在高可用范围内 |
| 节点 | 运行 SmartDNS + AdGuard + Keepalived 的 Debian 主机 |

## 配置与文件

| 术语 | 定义 |
| --- | --- |
| `smartdns.conf` | SmartDNS 主配置，`install_dns.sh` 生成 |
| `conf.d/` | SmartDNS 扩展目录，推荐的自定义入口，在配置同步范围内 |
| `AdGuardHome.yaml` | AdGuard 主配置（含管理密码 hash） |
| `keepalived.conf` | VRRP 实例、认证、VIP、健康检查配置 |
| `sync_daemon.sh` | 配置同步守护脚本，`sync_config.sh` 生成到 `/opt/dnsha/` |
| `dns_config_sync` | 运行同步守护脚本的 systemd 服务名 |
| 回滚基线 | `/opt/dnsha/*_default.*` 三份默认配置，`repair_dns.sh --rollback` 的输入 |
| drop-in | `/etc/netplan/99-dnsha-*.yaml`，不覆写系统既有 netplan 文件的增量配置 |

## 运维动作

| 术语 | 定义 |
| --- | --- |
| 巡检 | 用 `health_check.sh` 检查两节点与同步状态 |
| 计划内切换 | 主动停主节点 keepalived 让 VIP 漂移，用于维护 |
| 修复 | `repair_dns.sh` 重装/重启服务或同步 |
| 回滚 | 用默认配置覆盖当前配置并重启服务 |
| 演练 | 定期真实触发一次切换并记录中断时长 |

## 测试

| 术语 | 定义 |
| --- | --- |
| 自检 | `tests/selftest.sh`，对脚本与生成物做静态断言 |
| 运行态测试 | `tests/runtime.sh`，在 Debian 容器里真实执行脚本 |
| 双节点测试 | `tests/docker/run.sh`，两个特权容器验证 VIP 漂移与同步 |
| 门禁 | CI 中会阻断合并的检查：`bash -n`、shellcheck error/warning、两层测试 |
| 假阳性 | 测试通过但实际功能错误；本项目的历史教训之一是断言写得太宽 |

## 角色与流程

| 术语 | 定义 |
| --- | --- |
| ADR | 架构决策记录，解释"为什么这样设计"，见 [docs/adr/](docs/adr/) |
| wayfinder | 本仓库的 issue 组织方式，用一个地图 issue 串起子任务；标签 `wayfinder:<type>` |
| 三态标签 | 协作流程中的 `needs-triage` / `ready-for-agent` / `ready-for-human` 等状态，见 [docs/agents/triage-labels.md](docs/agents/triage-labels.md) |

## 相关文档

- [docs/README.md](docs/README.md)：从哪开始读
- [architecture.md](docs/architecture.md)：结构与不变量
- [docs/agents/domain.md](docs/agents/domain.md)：领域文档约定（单上下文）
