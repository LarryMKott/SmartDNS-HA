# 故障排查

按症状查表，再看下面对应的详细步骤。所有命令在**节点上以 root 执行**，除非标注"控制机"。

## 0. 先花 30 秒定位在哪一层

```bash
# 控制机
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once

# 节点上
ip -br addr show eth0                       # VIP 在不在
systemctl is-active smartdns adguardhome keepalived dns_config_sync
ss -tuln | grep -E ':(53|8080)\b'
dig @127.0.0.1 www.baidu.com +short
dig @<VIP> www.baidu.com +short
```

## 症状速查

| 症状 | 最可能原因 | 跳转 |
| --- | --- | --- |
| 两台都没有 VIP | keepalived 未启动 / 配置校验失败 / 接口名错 / VRRP 被网络拦截 | [A](#a-vip-不在任何节点) |
| 两台同时有 VIP | 两节点不通（split brain）/ `virtual_router_id` 冲突 / 认证口令不一致 | [B](#b-vip-同时出现在两台) |
| VIP 能 ping，dig 超时 | SmartDNS 未监听 / 防火墙丢 UDP / 客户端指向了旧地址 | [C](#c-vip-通但解析失败) |
| 解析偶尔超时/变慢 | 上游不通 / 测速模式依赖 ICMP / 缓存未命中 | [D](#d-解析慢或间歇超时) |
| 切换后配置是旧的 | 同步服务未运行 / SSH 免密不通 / 改的是备节点 | [E](#e-备节点配置没有同步) |
| 8080 打不开 | AdGuard 未启动 / 密码重置 / 防火墙 | [F](#f-adguard-管理界面打不开) |
| keepalived 起不来 | `keepalived -t` 报错（state/认证/语法） | [G](#g-keepalived-启动失败) |
| haproxy 模式报错 | `:53` 被 SmartDNS 占用 | [H](#h-haproxy-模式报错) |
| 部署时 SSH 失败 | 免密未配置 / 密码错 / 端口非 22 | [I](#i-部署时-ssh-失败) |
| 部署"成功"但服务没起来 | `verify_deploy.sh` 失败只告警，退出码仍 0 | [J](#j-部署看起来成功但服务不可用) |
| 同步日志刷错 | 源目录为空被保护 / 对端磁盘满 / 权限 | [K](#k-同步日志持续报错) |
| 重装后 AdGuard 密码变了 | 未设置 `ADGUARD_ADMIN_PASS` | [F](#f-adguard-管理界面打不开) |
| 重跑 install.sh 后本地改动没了 | `/opt/dnsha` 会被删除重建 | [L](#l-脚本改动丢失) |

---

## A. VIP 不在任何节点

```bash
systemctl status keepalived --no-pager -l
keepalived -t -f /etc/keepalived/keepalived.conf   # 打印原始错误
ip -br link                                        # 接口名是否与配置一致
journalctl -u keepalived -n 100 --no-pager
```

按顺序排除：

1. **服务没起**：`systemctl enable --now keepalived`，再看 `-t` 是否通过。
2. **接口名写错**：`keepalived.conf` 里的 `interface eth0` 与实际网卡不符时，keepalived 会进入 FAULT 状态，日志有 `Cannot find interface`。
3. **VRRP 不通**：跨网段/云网络组播被禁。两台都加上 `--unicast` 重新生成配置；同时确认安全组放行 VRRP（IP 协议 112）。
4. **两台 priority 相同**：例如都手工传了 `--priority 100`。改回 100/90。
5. **VIP 网段错**：`--vip` 必须带 CIDR 且与接口同网段。
6. **认证口令不一致**：两台 `VRRP_AUTH_PASS` 必须相同。

## B. VIP 同时出现在两台

这是 split brain，比"没有 VIP"更危险：两个节点都认为自己是主，客户端可能命中不同后端。

```bash
# 两台都执行
journalctl -u keepalived | grep -E 'VRRP_Instance|Entering|MASTER|BACKUP' | tail -20
grep -E 'virtual_router_id|priority|auth_pass|unicast' /etc/keepalived/keepalived.conf
ping -c 3 <对端IP>
```

常见原因：

| 原因 | 确认方式 | 处理 |
| --- | --- | --- |
| 两节点网络不通 | `ping` 失败 | 先修网络；这是根因 |
| `virtual_router_id` 与同网段其他集群冲突 | 抓包看是否有非本集群 VRRP 通告 | 改成唯一值，两台同步改 |
| 两节点都配置成 `state MASTER` 且 priority 相同 | 看配置文件 | 改成一主一备、100/90 |
| 中间设备过滤 VRRP 单播/组播 | 抓包 `tcpdump -i eth0 proto 112` | 放行或改单播 |

应急：在**备节点**执行 `systemctl stop keepalived`，让唯一的主节点持有 VIP，再排查。

## C. VIP 通但解析失败

```bash
ss -tuln | grep ':53'                 # 有没有监听
systemctl status smartdns --no-pager
tail -50 /var/log/smartdns.log
dig @127.0.0.1 www.baidu.com +short   # 本机解析是否正常
iptables -L INPUT -n --line-numbers | grep -E '53|8080'
```

- `:53` 没有监听 → SmartDNS 没起来，看 `journalctl -u smartdns`。二进制路径是 `/usr/local/sbin/smartdns`，PID 文件 `/run/smartdns.pid`。
- 本机能解析、VIP 不能 → 防火墙/安全组拦截 UDP 53，或客户端缓存了旧 VIP 的 ARP。客户端侧 `ip neigh flush all` 或重启网络。
- 监听在 `127.0.0.1:53` 而不是 `[::]:53` → 配置被改坏，重跑 `install_dns.sh` 恢复。
- 只 UDP 不通 → 检查 `bind-tcp` 是否缺失；部分网络会丢弃大 UDP 响应。

## D. 解析慢或间歇超时

```bash
dig @127.0.0.1 www.baidu.com +stats | grep -E 'Query time|SERVER'
grep -E 'speed-check|server ' /etc/smartdns/smartdns.conf
```

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 首次查询慢、后续快 | 缓存未命中，正常 | 关注 `cache-size` 是否被打满 |
| 全部慢 | 上游不可达 | `dig @114.114.114.114` 对比；换 `server` 分组 |
| 内网禁 ICMP 时慢 | `speed-check-mode ping` 超时 | 改为 `speed-check-mode tcp:80` 后 reload |
| 特定域名慢 | 该域名走错分组 | 用 `conf.d/` 加 `domain-rules` 指定 `-nameserver` |
| 周期性变慢 | 上游限速或运营商故障 | 增加上游、观察 `log-level debug` |

## E. 备节点配置没有同步

```bash
# 主节点
systemctl status dns_config_sync --no-pager
tail -50 /var/log/dnsha_sync_daemon.log
ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.102 true; echo "ssh rc=$?"
ls -ld /etc/smartdns /opt/AdGuardHome/conf
```

- `ssh rc≠0` → 免密没配好。在主节点执行 `ssh-copy-id root@192.168.1.102`，或重跑 `sync_config.sh`。
- 日志出现"源目录不存在或为空，已跳过" → 主节点配置目录真的为空，先修配置；这是防止 `--delete` 清空对端的保护。
- 日志无输出但服务 active → 确认改的是**主节点**的文件；在备节点上的修改会被下一次同步覆盖。
- 同步成功但服务行为没变 → 同步不重启服务，需要两台分别 `systemctl reload smartdns` / `restart adguardhome`。
- 备节点上的 `dns_config_sync` 指向自身属于预期（deploy 会在两台都装），可以 `systemctl disable --now dns_config_sync`。

## F. AdGuard 管理界面打不开

```bash
ss -tuln | grep ':8080'
systemctl status adguardhome --no-pager
tail -50 /var/log/AdGuardHome.log 2>/dev/null || journalctl -u adguardhome -n 50 --no-pager
grep -E 'bind_host|bind_port|auth_name|auth_pass' -A1 /opt/AdGuardHome/conf/AdGuardHome.yaml
```

- 端口未监听 → 服务没起来；二进制在 `/opt/AdGuardHome/AdGuardHome`，工作目录 `/opt/AdGuardHome`。
- 能打开但密码不对 → 重装时生成了新密码（脚本写入 `auth_name`/`auth_pass`）。用 `ADGUARD_ADMIN_PASS` 固定密码后重装；或登录管理台自行改密，不要手改未知版本的哈希字段。
- 8080 被防火墙拦截 → `iptables -C INPUT -p tcp --dport 8080 -j ACCEPT` 检查，缺失则补。
- 想限制访问来源 → 见 [security.md](security.md#4-暴露面)。

## G. keepalived 启动失败

```bash
keepalived -t -f /etc/keepalived/keepalived.conf
journalctl -u keepalived -n 100 --no-pager
```

高频错误：

| 报错关键词 | 原因 | 处理 |
| --- | --- | --- |
| `Unknown keyword` / `auth_pass` | 启用了 `vrrp_strict`，与认证冲突 | 删掉 `vrrp_strict`；重跑 `keepalived_config.sh` |
| `invalid state` / `SLAVE` | `state` 写了 `SLAVE` | 只能是 `MASTER`/`BACKUP` |
| `Cannot find interface` | 接口名错 | `ip -br link` 确认后重生成 |
| `Socket bind failed` | 已有 keepalived 实例或权限不足 | `systemctl stop keepalived` 后重试 |
| `VRRP_Instance ... no VIP` | VIP 段配置错误 | `--vip` 带 CIDR 重新生成 |

> 改完配置务必 `keepalived -t` 再重启，脚本本身也是这样做的。

## H. haproxy 模式报错

```
haproxy 模式需要独占 :53，但本机已有服务监听（smartdns/AdGuard）。
请改用 vrrp 模式，或先把 DNS 入口迁到 127.0.0.1:6053
```

这是**设计使然**：节点上 SmartDNS 已监听 `:53`。正确处理：

1. 不要在 DNS 节点上跑 haproxy 模式。
2. 用独立 LB 节点，只把 `keepalived_config.sh --failover-mode haproxy` 跑在 LB 上（见 [deployment.md](deployment.md#haproxy-模式独立-lb-节点)）。
3. 或者接受 vrrp 模式。

另外注意 haproxy 模式**不绑定 VIP**，客户端要指向 LB 实际地址。

## I. 部署时 SSH 失败

```
SSH连接失败: 192.168.1.101
```

```bash
# 控制机
ssh -o ConnectTimeout=5 root@192.168.1.101 true
command -v sshpass
```

- 免密未配置 → `ssh-copy-id root@192.168.1.101`。
- 用密码 → 控制机必须装 `sshpass`；密码含特殊字符时用单引号包住。
- SSH 端口不是 22 → 当前脚本不支持自定义端口，需要先做端口转发或在节点上改回 22。
- `/opt/dnsha` 不存在 → `scp` 目标目录缺失会失败，先确保两台节点跑过 `install.sh`。

## J. 部署看起来成功但服务不可用

`deploy_dns.sh` 最后一步 `verify_deploy.sh` 的失败是**警告级**，不会让退出码变成非 0。所以"脚本没报错"不代表部署成功。

```bash
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once
ssh root@192.168.1.101 '/opt/dnsha/verify_deploy.sh --vip 192.168.1.200 --role master'
```

按 `verify_deploy.sh` 的 9 项逐条修。`--vip` 参数这里要**纯 IP**，带掩码会校验失败。

## K. 同步日志持续报错

```bash
tail -100 /var/log/dnsha_sync_daemon.log
df -h / /opt            # 对端磁盘满会让 rsync 失败
ssh root@<主节点> 'ssh -o BatchMode=yes root@<备节点> true'
```

- `rsync: connection unexpectedly closed` → 免密失效或 sshd 限制。
- `No space left on device` → 清理对端磁盘。
- 频繁重连 → `dns_config_sync` 在 `Restart=on-failure` 下反复重启，先看守护进程为什么退出（`journalctl -u dns_config_sync`）。
- 权限错误 → 目标目录属主被改；恢复为 root:root。

## L. 脚本改动丢失

`install.sh` 第 7 步是 `rm -rf /opt/dnsha` 后重新 `git clone`。在节点上直接改的脚本会在重跑安装时全部丢失。

处理：改动走 git（fork/分支），在仓库里维护；或把定制放到 `/etc/smartdns/conf.d/` 这类不被覆盖的位置。

## M. 容器 / 云环境专项

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| keepalived 起不来，VIP 加不上 | 容器缺 `NET_ADMIN`/`NET_RAW` | 加 capability；仓库 `tests/docker` 就是这么跑的 |
| VIP 加上了但不响应 | 非本机 IP 绑定需要 `net.ipv4.ip_nonlocal_bind=1` | `sysctl -w net.ipv4.ip_nonlocal_bind=1` |
| 组播 VRRP 不通 | 容器/云网络禁组播 | 用 `--unicast` |
| 两台容器 VIP 都出现 | bridge 网络隔离导致互相收不到通告 | 同一自定义网络 + 单播 |

## N. 时间与日志异常

- `journalctl` 时间跳变 → 检查 NTP：`timedatectl status`。
- 日志太大 → `log-level info` 下正常；临时调过 `debug` 记得改回，并检查 `/var/log` 磁盘。

## 求助时请附上

```bash
uname -a; cat /etc/debian_version
ip -br addr; ip route
systemctl status smartdns adguardhome keepalived dns_config_sync --no-pager
journalctl -u keepalived -n 200 --no-pager
tail -100 /var/log/dnsha_sync_daemon.log
grep -vE 'auth_pass|password' /etc/keepalived/keepalived.conf
```

提交 issue 前先搜一下现有 issue；带上上面的输出（**记得脱敏口令**）。
