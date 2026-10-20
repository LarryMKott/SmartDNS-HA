# 架构

本文描述 DNSHA 在运行时的真实结构：有哪些进程、数据往哪走、故障时发生什么、哪些地方是刻意取舍。所有路径与端口均与仓库脚本一致。

## 目标与非目标

**目标**

- 两台 Debian 节点组成 DNS 主备，对外只暴露一个 VIP（虚拟 IP）。
- 主节点故障（进程挂了、DNS 不可解析、整机失联）时，VIP 在数秒内漂到备节点。
- 主节点配置变更能自动同步到备节点，避免"切过去才发现配置是旧的"。
- 全部用 Shell + 系统工具实现，目标机不需要 Python/Runtime，分发方式是 `curl | bash` 或 `git clone`。

**非目标**

- 不做跨三机房/多副本一致性：这是双节点主备，不是分布式数据库。
- 不做 DNS 递归解析器本身：上游解析交给 SmartDNS，过滤能力由 AdGuard Home 提供（默认不在 `:53` 主链路，见 [已知限制](#已知限制)）。
- 不做配置版本管理与审计：配置同步是"文件级覆盖"，历史版本要靠运维侧备份。
- 不提供 Web 控制台与卸载脚本。

## 组件与拓扑

```
                    ┌──────────────────────────────┐
   客户端 / 内网 ───▶│  VIP 192.168.1.200:53 (TCP/UDP)│
                    └──────────────┬───────────────┘
                                   │ VRRP 决定 VIP 落在哪台
          ┌────────────────────────┴────────────────────────┐
          │                                                  │
 ┌────────▼─────────┐  配置同步(inotify+rsync)   ┌───────────▼────────┐
 │ 主节点 master     │ ─────────────────────────▶ │ 备节点 backup      │
 │ smartdns   :53    │                            │ smartdns   :53     │
 │ AdGuard    5353   │                            │ AdGuard    5353    │
 │ AdGuard Web 8080  │                            │ AdGuard Web 8080   │
 │ keepalived (VIP)  │ ◀──── VRRP 通告(1s) ─────▶ │ keepalived (BACKUP)│
 │ dns_config_sync   │                            │ dns_config_sync    │
 └───────────────────┘                            └────────────────────┘
          ▲                                                  ▲
          └────────────── 控制机: ssh 部署/巡检 ──────────────┘
```

- **主/备不是固定身份**：`master`/`slave` 是部署时的角色参数，决定 keepalived 的初始 `state` 与 `priority`（100 / 90）。运行期谁持有 VIP 由 VRRP 选举决定，主节点恢复后会抢占回 VIP。
- **控制机是外部依赖**：`deploy_dns.sh`、`health_check.sh`、`repair_dns.sh` 都从控制机通过 SSH 远程执行，控制机不在高可用范围内。

## DNS 查询链路（默认配置）

```
客户端 → VIP:53 → SmartDNS(0.0.0.0/[::]:53)
                      ├─ 缓存 (cache-size 10000, TTL 60–3600s，持久化 /var/lib/smartdns/cache.db)
                      ├─ 测速选路 (speed-check-mode ping,tcp:80)
                      └─ 上游分组：default / aliyun / google
```

AdGuard Home 是**旁路过滤层**，不是 `:53` 的必经之路：

```
本机或显式指向 127.0.0.1:5353 的客户端 → AdGuard Home(:5353)
                                            ├─ 过滤规则（3 个订阅）
                                            └─ 上游 127.0.0.1:53 → SmartDNS → 公网
```

这意味着：**把 DNS 指向 VIP 的普通客户端不会经过 AdGuard 过滤**。要让过滤生效，需要把 AdGuard 的 DNS 端口提升到对外入口（例如让 AdGuard 监听 53、SmartDNS 退到 6053），这属于架构变更，必须同步修改 `install_dns.sh` 相关配置与健康检查，不能只改一个端口。详见 [ADR-0005](adr/0005-adguard-as-sidecar-filter.md)。

## 控制链路（部署时）

`deploy_dns.sh` 在控制机上按固定顺序串行执行，任一步失败即整体失败：

| 步骤 | 动作 | 失败表现 |
| --- | --- | --- |
| 1 | 参数校验（`master_ip`/`slave_ip` 必填，模式 ∈ vrrp/haproxy/consul） | 直接退出，不产生任何远程改动 |
| 2 | SSH 连通性测试（免密或 `sshpass` 密码），`ConnectTimeout=5` | 报"SSH连接失败"并退出 |
| 3 | `scp -r <脚本目录>/* root@node:/opt/dnsha/` | 报"复制脚本失败"；`/opt/dnsha` 不存在时 scp 本身会失败 |
| 4 | 远程 `./install_dns.sh --role master\|slave` | 主/备的 DNS 服务没装起来 |
| 5 | 远程 `./keepalived_config.sh --role ... --vip ... --interface ...` | keepalived 配置或启动失败 |
| 6 | 远程 `./sync_config.sh --role ... --master-ip ... --slave-ip ...` | 同步服务未就绪 |
| 7 | 远程 `./verify_deploy.sh --vip <纯IP> --role ...` | 只告警（`echo_warning`），不回滚、不退出非 0 |

注意第 7 步：部署脚本把验证失败当**警告**处理，退出码仍可能是 0。判定"部署成功"必须另跑 `health_check.sh --once` 或人工核对，见 [deployment.md](deployment.md#4-部署后验收)。

## 配置同步链路

```
主节点 /etc/smartdns/*            ─┐
主节点 /opt/AdGuardHome/conf/*    ─┴─ inotifywait -m -r ─▶ rsync -avz --delete
                                                            └─ ssh root@备节点:<同路径>
```

- 单向：只有主节点向备节点推，反向不同步。
- 触发：文件 `modify/create/delete/move`（忽略 `.swp/.swx/.tmp`），启动时先做一次全量同步。
- 保护：源目录不存在或为空时**拒绝同步**，避免 `--delete` 清空对端配置目录。
- 覆盖范围只有 `/etc/smartdns` 与 `/opt/AdGuardHome/conf`；**keepalived 配置、`/etc/hosts`、证书等不在同步范围**。
- 同步只搬文件，不重启服务：SmartDNS 需要 `systemctl reload smartdns`，AdGuard 需要 `systemctl restart adguardhome` 才读取新配置。
- 信任前提：主节点 root 到备节点 root 免密（`sync_config.sh` 会用 `ssh-copy-id` 建，失败则要求手工配置）。

## 故障检测与切换

keepalived 的健康检查脚本 `/etc/keepalived/check_dns.sh` 同时检查四件事，任一失败即判定节点不健康：

1. `systemctl is-active smartdns`
2. `systemctl is-active adguardhome`
3. `dig @127.0.0.1 www.baidu.com +short` 能返回结果
4. `netstat -tuln` 能看到 `:53` 或 `:8080`

关键参数（`keepalived_config.sh` 生成）：

| 参数 | 值 | 含义 |
| --- | --- | --- |
| `advert_int` | 1s | VRRP 通告间隔 |
| `priority` | 主 100 / 备 90 | 选举权重 |
| `weight` | -20 | 健康检查失败后主节点降为 80 |
| `fall` / `rise` | 2 / 2 | 连续 2 次失败降权，连续 2 次成功恢复 |
| `interval` | 2s | 健康检查周期 |
| `virtual_router_id` | 51 | 同一二层网络内必须唯一 |
| `state` | MASTER / BACKUP | 只允许这两个值（写 `SLAVE` 会被 `keepalived -t` 判非法） |

**主节点进程崩溃/整机断电**：备节点约 3 个通告周期（≈3s）未收到通告即接管 VIP。
**主节点 DNS 不健康但 keepalived 还活着**：健康检查连续失败 2 次（≈4s）后 priority 从 100 降到 80，低于备节点 90，VIP 漂移。
**主节点恢复**：默认开启抢占（未配 `nopreempt`），主节点 priority 回到 100 并重新通告后夺回 VIP。

> 不变量：`weight` 的绝对值必须大于主备 priority 差（20），否则降权后双方同分，VIP 归属由 IP 大小决定，故障就不会切换。`tests/selftest.sh` 对此有断言。

## 三种容灾模式

| 模式 | 谁持有 VIP | 入口 | 依赖 | 适用与限制 |
| --- | --- | --- | --- | --- |
| `vrrp`（默认） | Keepalived 在节点上漂移 | 节点本机 `:53` | 二层网络可通 VRRP（协议号 112），或使用 `--unicast` 点对点 | 生产推荐；跨网段/云网络需单播 |
| `haproxy` | **不绑定 VIP** | 独立 LB 节点 `*:53` | 该节点 `:53` 必须空闲 | 只做 TCP 轮询转发到两节点 `:53`；不能与节点本机 SmartDNS 共存，因此**不能直接套用一键部署** |
| `consul` | **不绑定 VIP** | 无（仅注册/发现） | 自行安装 Consul | 当前仅写配置、启动服务，不改变 DNS 入口，属于实验性 |

`deploy_dns.sh --failover-mode haproxy` 会在两台节点上先装 SmartDNS（占用 `:53`），再配置 haproxy（要求独占 `:53`），因此该组合会明确报错：

```
haproxy 模式需要独占 :53，但本机已有服务监听（smartdns/AdGuard）...
```

正确的 haproxy 用法见 [deployment.md](deployment.md#haproxy-模式独立-lb-节点)。

## 端口与文件

### 端口

| 端口 | 协议 | 组件 | 监听地址 | 说明 |
| --- | --- | --- | --- | --- |
| 22 | TCP | sshd | 全网 | 部署、巡检、同步都走 SSH |
| 53 | TCP/UDP | SmartDNS | `[::]:53`（双栈） | 对外 DNS 入口 |
| 8080 | TCP | AdGuard Home Web | `0.0.0.0` | 管理界面，默认账号 `admin`，密码见部署输出 |
| 5353 | TCP/UDP | AdGuard Home DNS | `127.0.0.1` | 仅本机可用，作为过滤层 |
| 112 | IP 协议 | VRRP | 节点间 | 组播/单播通告，不是 TCP/UDP 端口 |
| 8081 | TCP | Haproxy stats | `127.0.0.1` | 仅 haproxy 模式存在 |
| 8300/8301/8500/8600 | TCP/UDP | Consul | 视配置 | 仅在已自行安装 Consul 时存在 |

防火墙（`install_dns.sh`）只做"放行"，不改变默认策略：追加 `INPUT ACCEPT 53/tcp、53/udp、8080/tcp`，并用 `netfilter-persistent save` 持久化。SSH 与 VRRP 不在放行列表内，若系统默认策略是 DROP 需要自行放行。

### 安装后文件

| 路径 | 归属脚本 | 用途 |
| --- | --- | --- |
| `/opt/dnsha/` | `install.sh` | 仓库代码副本，所有脚本在此执行 |
| `/etc/smartdns/smartdns.conf`、`/etc/smartdns/conf.d/` | `install_dns.sh` | SmartDNS 配置与扩展目录 |
| `/var/lib/smartdns/cache.db` | SmartDNS | 缓存持久化 |
| `/opt/AdGuardHome/AdGuardHome`、`conf/AdGuardHome.yaml` | `install_dns.sh` | AdGuard 二进制与配置 |
| `/etc/systemd/system/smartdns.service`、`adguardhome.service` | `install_dns.sh` | 服务单元 |
| `/etc/keepalived/keepalived.conf`、`check_dns.sh`、`notify.sh` | `keepalived_config.sh` | VRRP 配置、健康检查、通知 |
| `/etc/haproxy/haproxy.cfg` | `keepalived_config.sh` | haproxy 模式配置 |
| `/etc/consul.d/consul_server.json` | `keepalived_config.sh` | consul 模式配置（需已装 consul） |
| `/opt/dnsha/sync_daemon.sh`、`/etc/systemd/system/dns_config_sync.service` | `sync_config.sh` | 同步守护进程与服务 |
| `/opt/dnsha/cloudflare_ddns.sh`、`cloudflare_ddns.{timer,service}` | `install.sh`（交互式） | IPv6 DDNS 每小时更新 |
| `/etc/netplan/99-dnsha-*.yaml` | `install.sh` | 网络 drop-in（不改写现有 netplan 文件） |

### 日志

| 日志 | 内容 |
| --- | --- |
| `/var/log/dnsha_deploy.log` | 控制机侧部署全过程（`log()` 用 `tee` 同时写终端） |
| `/var/log/dnsha_install.log` | 节点侧 DNS 安装 |
| `/var/log/dnsha_keepalived.log` | VRRP 配置过程 |
| `/var/log/dnsha_sync.log` | 同步服务配置过程 |
| `/var/log/dnsha_sync_daemon.log` | 实际的 rsync 结果（失败时先看这里） |
| `/var/log/dnsha_health.log` | 每次健康检查的摘要 |
| `/var/log/dnsha_repair.log` | 修复与回滚过程 |
| `/var/log/dnsha_verify.log` | 单节点验证输出 |
| `/var/log/keepalived_notify.log` | VRRP 状态通知（master/backup/fault/stop） |
| `/var/log/smartdns.log`、`/var/log/AdGuardHome.log` | DNS 组件日志 |
| `journalctl -u keepalived` | keepalived 自身的协议日志 |

## 暴露面与信任边界

- **信任**：控制机到两台节点的 root SSH；节点之间 root SSH（同步用）；VRRP 组播域。
- **不信任**：内网客户端对 `:53` 的查询（开放递归解析，`ratelimit: 0`、`allowed_clients: 0.0.0.0/0`，没有 ACL）。
- **默认暴露**：`:53`、`:8080`（AdGuard Web，全网可达）、`:22`。AdGuard 管理口令以明文写入 `AdGuardHome.yaml`，文件权限未由脚本收紧。
- **默认凭据**：VRRP 认证口令 `dnsha123`（脚本运行时读 `VRRP_AUTH_PASS` 覆盖，keepalived 只取前 8 位）；AdGuard 密码每次部署随机 16 位并打印在安装输出里。
- **控制机凭据**：`deploy_dns.sh` 支持 `--master-pwd/--slave-pwd` 走 `sshpass`，密码会出现在命令行参数、shell history 与进程列表中；生产环境应改用 root 免密 + `authorized_keys` 限制来源。

加固清单见 [security.md](security.md)。

## 设计取舍

| 取舍 | 选择 | 代价 |
| --- | --- | --- |
| 语言 | 纯 Shell | 无运行时依赖、分发简单；复杂逻辑靠 grep/awk 断言，可读性差，必须配 shellcheck 与运行态测试 |
| 容灾 | 默认 VRRP | 秒级漂移、无外部组件；要求二层可达，云网络/容器需单播 |
| 配置同步 | inotify + rsync | 延迟低、无需额外服务；单向、无冲突解决、只覆盖两个目录 |
| AdGuard 位置 | 旁路 `127.0.0.1:5353` | 不影响主链路可用性；但默认过滤不生效（见 ADR-0005） |
| 验证 | 三档（自检/容器运行态/双节点 Docker） | 能抓住"假成功"；CI 依赖容器特权与网络能力 |
| 默认口令 | 每节点随机生成 AdGuard 密码 | 避免弱口令；但密码出现在日志/终端输出，需要运维妥善保存 |

## 已知限制

以下是**当前代码的真实行为**，不是待办清单的美化版。每条都给出影响与绕过方式。

| # | 限制 | 影响 | 绕过 / 现状 |
| --- | --- | --- | --- |
| L1 | AdGuard 默认监听 `127.0.0.1:5353`，不在 `VIP:53` 链路 | 指向 VIP 的客户端不经过广告过滤 | 需要过滤时显式指向 `节点IP:5353`（仅本机监听，实际需改监听地址），或按 ADR-0005 调整入口 |
| L2 | haproxy 模式与本地 SmartDNS 争 `:53` | `deploy_dns.sh --failover-mode haproxy` 必然报错 | 用独立 LB 节点手动执行 `keepalived_config.sh --failover-mode haproxy`，并自行提供 VIP |
| L3 | consul 模式不安装 Consul，也不接管 VIP | 该模式只写配置，DNS 入口不变 | 自行安装 Consul；需要 VIP 时仍用 vrrp 模式 |
| L4 | `repair_dns.sh --rollback` 依赖 `/opt/dnsha/smartdns_default.conf`、`adguard_default.yaml`、`keepalived_default.conf` | 仓库不生成这三个文件，缺失时脚本明确拒绝回滚（不会假成功） | 首次部署后手工把三份配置复制到 `/opt/dnsha/` 作为"默认版本" |
| L5 | `health_check.sh` 除参数错误外始终退出 0 | 不能直接做 CI/监控门禁 | 解析输出中的"整体状态"，或按 [operations.md](operations.md#1-日常巡检) 自行包装退出码 |
| L6 | `install.sh` 要求 Debian 13+，CI 运行态测试用 Debian 12 | 支持矩阵与验证环境不一致 | 生产按 Debian 13+ 准备；Debian 12 仅用于脚本逻辑回归 |
| L7 | `sync_interval` 配置项与 `--interval` 参数未生效 | 同步由 inotify 事件驱动，改间隔没有效果 | 无需调整；若需要节流，改 `sync_daemon.sh` 的 rsync 调用 |
| L8 | 部署密码经命令行传入 | 泄漏到 history / `ps` | 用 root 免密；或部署后清理 history |
| L9 | AdGuard 密码明文存于 `AdGuardHome.yaml` | 拿到文件即可登录管理台 | `chmod 600 /opt/AdGuardHome/conf/AdGuardHome.yaml`，首次登录后改密 |
| L10 | VRRP 默认口令 `dnsha123`，最长 8 位 | 同二层网络可伪造通告 | 在节点上以内联 `VRRP_AUTH_PASS=<8位随机>` 重跑 `keepalived_config.sh`；网络侧限制 VRRP |
| L11 | 同步单向主→备，且备节点也会创建同步服务 | 备节点上的服务指向自身，实际无同步意义 | 备节点上 `systemctl disable --now dns_config_sync` 不影响切换 |
| L12 | SmartDNS 从源码 master 编译 | 上游变更会导致每次安装结果不同 | 需要可重复构建时改 `install_dns.sh` 固定 tag/commit |
| L13 | 无卸载脚本 | 只能手工清理 | 按 [operations.md](operations.md#8-卸载) 的顺序手工执行 |
| L14 | 仓库没有性能基准；README 中的 QPS/切换时延是设计目标 | 不能当作实测数据对外承诺 | 用 `dnsperf` 自测，结果写入自己的容量记录 |
| L15 | haproxy stats 口令写在配置里但不打印 | 运维需要自己读文件 | `grep 'stats auth' /etc/haproxy/haproxy.cfg` |
| L16 | Consul 的 `bind_addr` 取 `hostname -I` 的第一个地址 | 多网卡环境可能绑错网卡 | 手工改 `/etc/consul.d/consul_server.json` 后重启 |
| L17 | `deploy_dns.sh` 通过 SSH 执行远端脚本，**不转发**本地环境变量 | `ADGUARD_ADMIN_PASS`、`VRRP_AUTH_PASS`、`HAPROXY_STATS_PASS` 在控制机上 export 对节点无效 | 在节点上以内联形式重跑对应脚本（`ssh root@节点 'VAR=值 /opt/dnsha/xxx.sh ...'`） |

## 相关文档

- 部署细节：[deployment.md](deployment.md)
- 配置文件字段：[configuration.md](configuration.md)
- 日常运维：[operations.md](operations.md)
- 故障排查：[troubleshooting.md](troubleshooting.md)
- 架构决策：[docs/adr/](adr/)
