# DNSHA 文档

本目录是 SmartDNS-HA（DNSHA）的完整文档。根目录的 [README.MD](../README.MD) 只负责"三分钟跑起来"，这里负责"看懂、改对、排得了故障"。

## 文档约定

- **以代码为准**：文中的参数、路径、服务名、默认值全部来自仓库脚本本身，不写"应该是"的东西；脚本行为与文档冲突时，先改文档，再判断脚本是否该改。
- **写清边界**：能做什么、不能做什么、什么条件下会失败，都写在正文里；已知限制集中记录在 [known-limitations](architecture.md#已知限制)，不在各处零散"温馨提示"。
- **一处定义，多处引用**：术语走 [GLOSSARY.md](../GLOSSARY.md)，架构决策走 [docs/adr/](adr/)，排障步骤走 [troubleshooting.md](troubleshooting.md)，其他文档只做链接。

## 按角色进入

| 我是谁 / 我要做什么 | 先读 | 再读 |
| --- | --- | --- |
| 第一次部署，想尽快跑通主备 | [快速开始](../README.MD#快速开始) | [installation.md](installation.md) → [deployment.md](deployment.md) |
| 要知道这套东西怎么运转的 | [architecture.md](architecture.md) | [configuration.md](configuration.md) |
| 要改脚本/加功能 | [CONTRIBUTING.md](../CONTRIBUTING.md) | [testing.md](testing.md) → [GLOSSARY.md](../GLOSSARY.md) |
| 线上出问题，正在救火 | [troubleshooting.md](troubleshooting.md) | [operations.md](operations.md) |
| 做安全评审/合规检查 | [security.md](security.md) | [architecture.md](architecture.md#暴露面与信任边界) |
| 接手维护，想知道为什么这么设计 | [docs/adr/](adr/) | [architecture.md](architecture.md) |

## 文档清单

| 文档 | 回答什么问题 | 什么时候必须改 |
| --- | --- | --- |
| [architecture.md](architecture.md) | 有哪些组件、怎么连、故障时发生什么、边界在哪 | 新增组件/端口/模式，或切换流程变化 |
| [installation.md](installation.md) | 节点如何初始化：系统要求、网络、`install.sh`、DDNS | `install.sh` 参数或写入的系统文件变化 |
| [deployment.md](deployment.md) | 如何把两台节点组成主备：一键部署、配置文件、分步部署 | `deploy_dns.sh` / `keepalived_config.sh` / `sync_config.sh` 参数变化 |
| [configuration.md](configuration.md) | 每个配置文件长什么样、哪些字段关键、改完怎么生效 | 生成的配置模板或环境变量变化 |
| [operations.md](operations.md) | 日常巡检、主备切换、变更、回滚、升级、卸载 | 运维动作、日志路径、服务名变化 |
| [troubleshooting.md](troubleshooting.md) | 某个症状该查什么、怎么恢复 | 出现新的高发故障 |
| [testing.md](testing.md) | 三层验证（自检/运行态/双节点）与 CI 门禁怎么跑 | 测试脚本或 workflow 变化 |
| [security.md](security.md) | 信任模型、凭据、暴露面、加固清单 | 凭据处理、监听地址、防火墙策略变化 |
| [adr/](adr/) | 关键技术决策的背景与代价 | 推翻既有决策时新增 ADR，不改旧 ADR |
| [agents/](agents/) | 给协作 Agent 的 issue/triage/domain 约定 | 工作流约定变化 |

## 30 秒版本

DNSHA 用纯 Shell 把两台 Debian 节点组成一套 DNS 主备：

1. `install.sh`：在**每台节点**上初始化系统（Debian 13+、网络、依赖、代码到 `/opt/dnsha`）。
2. `deploy_dns.sh`：在**控制机**上通过 SSH 把两台节点装成一套服务（SmartDNS + AdGuard Home + Keepalived + 配置同步）。
3. `health_check.sh` / `verify_deploy.sh`：验证"真的能解析、VIP 真的只在一台、同步真的通"。

默认模式是 VRRP：主节点持有 VIP 并在故障时把 VIP 漂到备节点。另外两种模式（Haproxy、Consul）的定位与限制见 [deployment.md](deployment.md#6-三种容灾模式怎么选)。

## 改文档的规矩

- 改脚本的 PR，必须在同一个 PR 里更新受影响的文档；只改代码不改文档视为未完成。
- 文档里出现的命令要能直接复制执行（不要写 `# 注释` 在续行符后面，那会把命令打断）。
- 新增"已知限制"时，同时在 [architecture.md](architecture.md#已知限制) 登记，并说明影响与绕过方式。
