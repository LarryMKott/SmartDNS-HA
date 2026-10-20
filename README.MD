# DNSHA

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Script-89e051.svg)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/OS-Debian%2013+-blue.svg)](https://www.debian.org/)

DNSHA 是一套**纯 Shell 实现**的 DNS 主备容灾方案：用 SmartDNS + AdGuard Home 提供解析与过滤，用 Keepalived 管理浮动 VIP，用 inotify + rsync 把主节点配置实时同步到备节点。目标是在两台 Debian 上，用一条命令搭出"主节点挂了，VIP 几秒内漂到备节点"的 DNS 服务。

- **零运行时**：只用 Bash 与系统工具，没有 Python/Node/Go 依赖。
- **一键部署**：控制机通过 SSH 完成两台节点的安装、容灾配置、同步与验证。
- **可验证**：三层测试（静态断言 / Debian 容器运行态 / 双节点真实漂移）加 CI 门禁。
- **可运维**：巡检、修复、回滚、切换演练都有对应脚本与文档。

> **先读这个**：[架构与已知限制](docs/architecture.md#已知限制)。默认配置下 AdGuard 是**旁路过滤层**（`127.0.0.1:5353`），指向 VIP 的客户端不经过广告过滤；haproxy/consul 两种模式不接管 VIP。这些是设计取舍，不是 bug。

## 目录

- [能力边界](#能力边界)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [脚本一览](#脚本一览)
- [部署后验收](#部署后验收)
- [常用运维](#常用运维)
- [故障排查](#故障排查)
- [文档索引](#文档索引)
- [测试与 CI](#测试与-ci)
- [安全提示](#安全提示)
- [项目状态与路线图](#项目状态与路线图)
- [许可证](#许可证)

## 能力边界

**能做**

- 两台 Debian 节点组成 DNS 主备，对外暴露一个 VIP。
- 主节点进程崩溃、解析异常、整机失联时自动漂移 VIP（设计目标：秒级）。
- 主节点配置变更自动同步到备节点（秒级，目录级镜像）。
- 双节点巡检、单节点 9 项验证、一键修复、配置回滚（需预置回滚基线）。
- 可选 Cloudflare IPv6 DDNS（每小时更新 AAAA）。

**不能做 / 需要注意**

| 限制 | 说明 |
| --- | --- |
| 过滤默认不生效 | AdGuard 监听 `127.0.0.1:5353`，VIP `:53` 由 SmartDNS 直接服务 |
| haproxy 模式不能一键部署 | 该模式要求独占 `:53`，与节点上的 SmartDNS 冲突；需独立 LB 节点 |
| consul 模式不接管 VIP | 只写配置、启动服务，DNS 入口不变 |
| 回滚需要预置基线 | `/opt/dnsha/*_default.*` 仓库不生成，缺失时脚本明确拒绝 |
| 巡检退出码不可靠 | `health_check.sh` 除参数错误外恒为 0，需解析输出 |
| 无性能基准 | 下文 QPS/切换时延均为设计目标，非实测数据 |

完整 16 条限制见 [docs/architecture.md](docs/architecture.md#已知限制)。

## 环境要求

| 角色 | 要求 |
| --- | --- |
| 主/备节点 | Debian 13（trixie）及以上，root，x86_64/aarch64/armv7/armv6，建议 ≥1 GB 内存 |
| 控制机 | 任意 Linux，能 SSH 到两台节点；密码方式需 `sshpass` |
| 网络 | 两节点二层互通（或改用 VRRP 单播）；VIP 与节点同网段且未被占用 |

需要放行的端口：

| 端口/协议 | 用途 |
| --- | --- |
| 22/TCP | 部署、巡检、同步 |
| 53/TCP+UDP | DNS 服务（VIP） |
| 8080/TCP | AdGuard Home 管理界面 |
| 112（IP 协议） | VRRP 通告（组播或单播） |
| 8300–8600/TCP+UDP | 仅 consul 模式，且需自行安装 Consul |

## 快速开始

### 1. 初始化两台节点

在**每台节点**上执行（把 IP/网关/网卡换成你的）：

```bash
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh \
  | bash -s -- --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0
```

```bash
# 备节点
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh \
  | bash -s -- --ipv4 192.168.1.102/24 --gateway 192.168.1.1 --interface eth0
```

国内网络加 `--cn`（apt 换中科大镜像、GitHub 走代理、代码从 Gitee 克隆）：

```bash
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh \
  | bash -s -- --cn --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0
```

> `curl | bash` 时**必须显式传网络参数**。不传会进入交互式配置，而 `read` 会把脚本剩余内容当成输入吃掉。原因与替代写法见 [docs/installation.md](docs/installation.md#43-远程-curl--bash-的正确姿势)。

也可以用 git：

```bash
git clone https://github.com/LarryMKott/SmartDNS-HA.git
cd SmartDNS-HA
sudo bash install.sh --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0
```

### 2. 在控制机部署主备

```bash
# 控制机：需要 root 权限与到两台节点的 SSH（推荐免密）
sudo ./deploy_dns.sh \
  --master-ip 192.168.1.101 \
  --slave-ip 192.168.1.102 \
  --vip 192.168.1.200/24 \
  --interface eth0
```

密码方式（会进 shell history，生产不推荐）：

```bash
sudo ./deploy_dns.sh \
  --master-ip 192.168.1.101 \
  --slave-ip 192.168.1.102 \
  --master-pwd '主节点root密码' \
  --slave-pwd '备节点root密码' \
  --vip 192.168.1.200/24 \
  --interface eth0
```

用配置文件（**等号两边不能有空格**；文件优先于命令行参数）：

```bash
cat > /root/dnsha.env <<'EOF'
master_ip=192.168.1.101
slave_ip=192.168.1.102
vip=192.168.1.200/24
interface=eth0
failover_mode=vrrp
EOF

sudo ./deploy_dns.sh --config /root/dnsha.env
```

### 3. 验收

```bash
# 双节点总体状态（只跑一次）
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once

# 从任意内网机器验证解析
dig @192.168.1.200 www.baidu.com +short
```

不要只看"部署脚本没报错"——`verify_deploy.sh` 的失败只算警告。完整验收清单见 [部署后验收](#部署后验收)。

## 脚本一览

| 脚本 | 在哪跑 | 作用 | 关键参数 |
| --- | --- | --- | --- |
| `install.sh` | 节点 | 系统初始化：Debian 校验、网络、apt 依赖、代码到 `/opt/dnsha`、可选 DDNS | `--ipv4` `--gateway` `--ipv6` `--interface` `--cn` |
| `deploy_dns.sh` | 控制机 | 一键编排：SSH 测试 → 拷脚本 → 两节点安装/容灾/同步 → 验证 | `--master-ip` `--slave-ip` `--vip` `--interface` `--failover-mode` `--config` |
| `install_dns.sh` | 节点 | 编译安装 SmartDNS、下载安装 AdGuard Home、写配置与服务 | `--role master\|slave` |
| `keepalived_config.sh` | 节点 | 生成 VRRP/haproxy/consul 配置、健康检查与通知脚本 | `--role` `--vip` `--interface` `--master-ip` `--slave-ip` `--priority` `--unicast` `--failover-mode` |
| `sync_config.sh` | 节点 | 生成配置同步守护进程与 systemd 服务 | `--role` `--master-ip` `--slave-ip` |
| `verify_deploy.sh` | 节点 | 单节点 9 项验证 | `--vip`（纯 IP） `--role` |
| `health_check.sh` | 控制机 | 双节点巡检，可循环刷新 | `-m` `-s` `-v` `-i` `--once` |
| `repair_dns.sh` | 控制机 | 修复 DNS/容灾/同步，或回滚 | `-m` `-s` `-d` `-f` `-y` `-r` |

参数细节：[installation.md](docs/installation.md)、[deployment.md](docs/deployment.md)、[configuration.md](docs/configuration.md)。

## 部署后验收

| # | 检查 | 命令 | 期望 |
| --- | --- | --- | --- |
| 1 | VIP 只在一台 | `ssh root@<主节点> 'ip -br addr show eth0'` | 主节点有 VIP，备节点没有 |
| 2 | VIP 能解析 | `dig @<VIP> www.baidu.com +short` | 返回 IP，无超时 |
| 3 | 管理界面 | `curl -s -o /dev/null -w '%{http_code}' http://<节点>:8080/` | `200` |
| 4 | 节点自检 | `ssh root@<节点> '/opt/dnsha/verify_deploy.sh --vip <VIP纯IP> --role master'` | 退出码 0 |
| 5 | 双节点巡检 | `./health_check.sh -m ... -s ... -v ... -o` | 整体 `healthy` |
| 6 | 配置同步 | 改主节点文件后看备节点 | 5 秒内一致 |
| 7 | 切换演练 | 停主节点 keepalived | VIP 漂到备节点，恢复后回切 |

切换演练会短暂中断解析，请在维护窗口做。步骤见 [operations.md](docs/operations.md#2-主备切换)。

## 常用运维

```bash
# 巡检（循环，Ctrl+C 退出）
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 -i 5

# 只跑一次
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once

# 全量修复
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102

# 只修 DNS
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102 --dns

# 回滚（需先预置 /opt/dnsha/*_default.*，见 docs/operations.md#43-创建回滚基线）
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102 --rollback

# 手动切换：主节点释放 VIP
ssh root@192.168.1.101 'systemctl stop keepalived'
# 恢复并回切
ssh root@192.168.1.101 'systemctl start keepalived'

# 日志
tail -f /var/log/dnsha_sync_daemon.log      # 同步
journalctl -u keepalived -n 50 --no-pager   # VRRP
tail -f /var/log/smartdns.log               # 解析
```

完整运维手册：[docs/operations.md](docs/operations.md)。

## 故障排查

| 现象 | 先看 |
| --- | --- |
| VIP 不在任何节点 | `keepalived -t`、接口名、VRRP 是否被网络拦截 |
| VIP 同时在两台 | 两节点是否互通、`virtual_router_id` 是否冲突 |
| VIP 通但解析失败 | `ss -tuln \| grep :53`、SmartDNS 服务、防火墙 |
| 切换后配置是旧的 | `dns_config_sync`、SSH 免密、是否改在备节点 |
| 8080 打不开 | AdGuard 服务、密码是否被重装重置、防火墙 |
| 部署"成功"但不可用 | `verify_deploy.sh` 失败只告警，需手动巡检 |

逐条定位：[docs/troubleshooting.md](docs/troubleshooting.md)。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/README.md](docs/README.md) | 文档入口与阅读路径 |
| [docs/architecture.md](docs/architecture.md) | 组件、链路、切换时序、端口文件、16 条已知限制 |
| [docs/installation.md](docs/installation.md) | 节点初始化、网络、`install.sh`、DDNS |
| [docs/deployment.md](docs/deployment.md) | 一键/分步部署、配置文件、三种模式 |
| [docs/configuration.md](docs/configuration.md) | SmartDNS/AdGuard/Keepalived/haproxy/consul/同步配置 |
| [docs/operations.md](docs/operations.md) | 巡检、切换、变更、备份、回滚、升级、卸载 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 症状表与处理步骤 |
| [docs/testing.md](docs/testing.md) | 三层测试与 CI 门禁 |
| [docs/security.md](docs/security.md) | 信任模型、凭据、暴露面、加固清单 |
| [docs/adr/](docs/adr/) | 架构决策记录 |
| [GLOSSARY.md](GLOSSARY.md) | 术语表 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献流程与规范 |

## 测试与 CI

```bash
# 静态自检（秒级，改任何脚本都该跑）
bash tests/selftest.sh

# 运行态（需 Debian 12 容器 + root）
bash tests/runtime.sh

# 双节点真实漂移（需 Docker + compose）
bash tests/docker/run.sh
```

CI（push 到 `master` / PR / 手动触发）：

- `verify`：全量 `bash -n`、`tests/selftest.sh`、shellcheck error + warning 双门禁。
- `runtime`：Debian 12 容器跑 `tests/runtime.sh`。
- `docker`：双节点容器验证 VIP 漂移、回切、跨机同步与空源保护。

细节见 [docs/testing.md](docs/testing.md)。

## 安全提示

默认配置面向**可信内网**，上线前至少完成：

1. 设置 `VRRP_AUTH_PASS`（默认口令 `dnsha123`，keepalived 只取前 8 位）。
2. 设置 `ADGUARD_ADMIN_PASS`，并把 `AdGuardHome.yaml` 权限收紧到 `600`。
3. 限制 8080 来源 IP；不要让管理界面暴露到公网。
4. 配置 root 免密 SSH 并禁用密码登录；部署后清理含密码的 history。
5. 评估 `:53` 的开放范围，避免被当作 DNS 放大器。

完整加固清单与已知弱点：[docs/security.md](docs/security.md)。

## 项目状态与路线图

- 当前状态：8 个 Shell 脚本 + 三层测试 + CI，`master` 即最新代码，**未打正式 tag**。
- 已知限制如实记录在 [docs/architecture.md](docs/architecture.md#已知限制)，包括过滤默认不生效、haproxy/consul 模式不完整、回滚依赖预置基线等。
- 扩展方向（**尚未实现**，欢迎 issue/PR）：
  - 让过滤覆盖全部客户端（需要重构 DNS 入口，见 [ADR-0005](docs/adr/0005-adguard-as-sidecar-filter.md#如果要让过滤覆盖全部客户端)）。
  - Prometheus 指标导出与 Grafana 面板。
  - 多云/多组主备的批量部署。
  - 卸载脚本与配置审计。
  - 性能基准（`dnsperf`）与容量记录模板。

## 许可证

[MIT](LICENSE)。

## 参考

- [SmartDNS 官方文档](https://pymumu.github.io/smartdns/)
- [AdGuard Home 官方文档](https://github.com/AdguardTeam/AdGuardHome/wiki)
- [Keepalived 官方文档](https://keepalived.readthedocs.io/)
- [Consul 官方文档](https://developer.hashicorp.com/consul/docs)
