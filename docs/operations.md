# 运维手册

本页是"装好之后怎么活"的部分：日常巡检、主备切换、变更、备份、回滚、升级、卸载。故障现象与定位见 [troubleshooting.md](troubleshooting.md)。

## 1. 日常巡检

### 1.1 一条命令看总体

```bash
sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once
```

对每台节点检查 8 项：SSH 可达、SmartDNS、AdGuard、keepalived（失败只告警）、VIP 绑定（精确匹配）、`dig @127.0.0.1`、配置同步（失败只告警）、磁盘使用率（<80% 正常，80–90% 告警，≥90% 失败）。最后比对主备同步状态，并给出整体状态：`healthy` / `warn` / `error`，以及 VIP 当前在哪台。

**注意退出码**：`health_check.sh` 除参数错误外始终返回 0，不能直接拿来做监控告警。需要机器判定时，解析输出中的"整体状态"：

```bash
out=$(sudo ./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once)
echo "$out" | grep -q '整体状态.*healthy' || echo "DNSHA 异常" | mail -s 'DNSHA' ops@example.com
```

### 1.2 巡检节奏建议

| 频率 | 动作 |
| --- | --- |
| 每 5 分钟 | 从内网机器 `dig @<VIP> www.baidu.com +short`，连续 3 次失败告警 |
| 每小时 | 看 `/var/log/keepalived_notify.log` 是否有非预期切换 |
| 每天 | `health_check.sh --once`，检查磁盘与同步日志错误 |
| 每周 | 核对备节点配置与主节点一致；确认备份可恢复 |
| 每季度 | 做一次计划内切换演练（见 2.4） |

### 1.3 巡检常看的位置

```bash
ip -br addr show eth0                 # VIP 在哪台
systemctl status smartdns adguardhome keepalived dns_config_sync --no-pager
journalctl -u keepalived -n 50 --no-pager
tail -n 50 /var/log/keepalived_notify.log
tail -n 50 /var/log/dnsha_sync_daemon.log
dig @127.0.0.1 www.baidu.com +short
ss -tuln | grep -E ':(53|8080|5353)\b'
df -h /
```

## 2. 主备切换

### 2.1 自动切换（故障）

触发条件：keepalived 进程消失、整机不可达（约 3 个通告周期 ≈ 3s），或健康检查连续失败 2 次（≈4s）导致优先级降到 80 < 备节点 90。

确认切换完成：

```bash
ssh root@192.168.1.101 'ip -br addr show eth0 | grep -w 192.168.1.200 || echo "主节点已释放 VIP"'
ssh root@192.168.1.102 'ip -br addr show eth0 | grep -w 192.168.1.200 && echo "备节点已接管"'
dig @192.168.1.200 www.baidu.com +short
```

### 2.2 手动切换（计划内）

```bash
# 1) 在主节点停 keepalived，释放 VIP（不会停 SmartDNS/AdGuard）
ssh root@192.168.1.101 'systemctl stop keepalived'

# 2) 等 3–5 秒，确认 VIP 已到备节点
sleep 5
ssh root@192.168.1.102 'ip -br addr show eth0 | grep -w 192.168.1.200'

# 3) 从内网验证解析
dig @192.168.1.200 www.baidu.com +short
```

主节点恢复后（`systemctl start keepalived`）默认会**抢占**回 VIP，因为 priority 100 > 90 且未配置 `nopreempt`。如果不希望自动回切，需要在 `keepalived.conf` 的 `vrrp_instance` 中加 `nopreempt`（脚本不生成，需自行维护并同步到两台）。

### 2.3 切换后必做

1. 确认备节点上的 SmartDNS/AdGuard 配置是新的（`diff` 关键文件）。
2. 备节点执行一次 `systemctl reload smartdns`（同步只搬文件，不重载服务）。
3. 检查日志：`/var/log/keepalived_notify.log`、`/var/log/dnsha_sync_daemon.log`。
4. 修好原主节点后，决定是否回切；回切同样走 2.2。

### 2.4 切换演练（季度）

```bash
# 记录基线
dig @192.168.1.200 www.baidu.com +short
# 停主节点 keepalived，计时到 VIP 出现在备节点
# 恢复主节点 keepalived，计时到 VIP 回切
# 期间持续 dig，统计中断时长
```

把实测的中断秒数记录到自己的容量档案——仓库不提供性能基准，`README` 里的切换时延是设计目标，不是实测值。

## 3. 变更管理

### 3.1 DNS 配置变更

见 [configuration.md](configuration.md#10-配置变更流程生产)。核心顺序：**主节点改 → 确认同步 → 两台重载 → 验证**。

### 3.2 网络/接口变更

接口名或 VIP 变化时，keepalived 配置必须重生成：

```bash
ssh root@<节点> '/opt/dnsha/keepalived_config.sh --role <master|slave> \
  --vip <新VIP/CIDR> --interface <新网卡> \
  --master-ip 192.168.1.101 --slave-ip 192.168.1.102'
```

两台都要改；只改一台会出现"两台都认为自己是主"或"都不持有 VIP"。改完 `keepalived -t` 校验并重启。

### 3.3 新增域名分流

优先写到 `/etc/smartdns/conf.d/`（在同步范围内，且不覆盖主配置）：

```bash
cat > /etc/smartdns/conf.d/20-split.conf <<'EOF'
domain-rules /example.com/ -nameserver aliyun
EOF
systemctl reload smartdns
ssh root@192.168.1.102 'systemctl reload smartdns'
```

## 4. 备份

### 4.1 需要备份什么

| 内容 | 路径 | 说明 |
| --- | --- | --- |
| SmartDNS 配置 | `/etc/smartdns/` | 含 `conf.d/` |
| AdGuard 配置 | `/opt/AdGuardHome/conf/AdGuardHome.yaml` | 含管理口令（脚本写入明文） |
| Keepalived 配置 | `/etc/keepalived/` | 含认证口令 |
| 同步脚本 | `/opt/dnsha/sync_daemon.sh` | 生成物，重跑可重建 |
| 网络配置 | `/etc/netplan/99-dnsha-*.yaml` | 重跑 `install.sh` 可重建 |
| 回滚默认配置 | `/opt/dnsha/*_default.*` | 需要手工创建，见 4.3 |

### 4.2 一次性打包

```bash
ts=$(date +%Y%m%d-%H%M%S)
tar czf /root/dnsha-backup-$ts.tar.gz \
  /etc/smartdns /opt/AdGuardHome/conf/AdGuardHome.yaml /etc/keepalived \
  /opt/dnsha/sync_daemon.sh /etc/netplan
```

备份包含口令（VRRP 认证、AdGuard 管理密码明文），按敏感文件保管，外传前加密。

### 4.3 创建回滚基线

`repair_dns.sh --rollback` 要求节点上存在三份默认配置。首次部署成功后执行：

```bash
ssh root@192.168.1.101 'cp /etc/smartdns/smartdns.conf /opt/dnsha/smartdns_default.conf; \
  cp /opt/AdGuardHome/conf/AdGuardHome.yaml /opt/dnsha/adguard_default.yaml; \
  cp /etc/keepalived/keepalived.conf /opt/dnsha/keepalived_default.conf'
```

两台节点都做一遍（回滚是逐节点执行的）。不做这一步，回滚会明确失败并提示"缺少 /opt/dnsha 默认配置，无法回滚"。

## 5. 回滚

```bash
# 回滚两台的配置并重启服务（脚本对 -m 与 -s 两台都执行）
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102 --rollback
```

它没有"只回滚一台"的开关。确实只需要回滚单台时，直接登录那台节点，把 `/opt/dnsha/*_default.*` 拷回对应路径并重启三个服务；另一台保持不动。

行为：先把当前配置备份到 `/tmp/dnsha_backup/<时间戳>/`，再用 `/opt/dnsha/*_default.*` 覆盖，最后重启 `smartdns adguardhome keepalived dns_config_sync`。回滚后校验两台服务是否 active，任一非 active 退出 1。

回滚前确认基线内容是"想回到的版本"，而不是随便一份旧文件。

## 6. 修复

`repair_dns.sh` 不带 `--rollback` 时默认做三件事（也可以用 `-d/--dns`、`-f/--failover`、`-y/--sync` 单独指定）：

- 修复 DNS：重启/补齐 SmartDNS 与 AdGuard 服务。
- 修复容灾：重生成并重启 keepalived。
- 修复同步：重装同步服务。

```bash
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102
```

它通过 SSH 免密执行，**控制机必须能 root 免密登录两台节点**（脚本不使用 `sshpass`）。

## 7. 升级

```bash
# 控制机：拉新代码
git pull
# 重新部署（会重装服务、重写配置、重启 keepalived/同步）
sudo ./deploy_dns.sh --config /root/dnsha.env
# AdGuard 密码默认会重新生成，注意记录。
# 要固定密码：deploy 不会透传环境变量，需在每台节点上以内联形式重装：
#   ssh root@<节点> 'ADGUARD_ADMIN_PASS="<原密码>" /opt/dnsha/install_dns.sh --role <role>'
```

升级注意：

- `install_dns.sh` 每次都从源码 master 编译 SmartDNS，**版本不可复现**。要稳定版本，先改脚本固定 tag/commit。
- 重装会重写 `smartdns.conf` 与 `AdGuardHome.yaml`；自定义内容请放在 `conf.d/` 或升级前备份。
- 先升备节点、验证后再升主节点，避免同时中断解析。

推荐顺序：

1. 停备节点 keepalived（它本来不持有 VIP，影响为零）。
2. 在备节点跑 `install_dns.sh` + `keepalived_config.sh`。
3. 手动切主（2.2），验证备节点承载正常。
4. 升级原主节点，验证后回切。

## 8. 卸载

没有卸载脚本，按顺序手工执行：

```bash
# 1) 停服务并禁用
systemctl disable --now keepalived dns_config_sync smartdns adguardhome 2>/dev/null

# 2) 删除服务单元与配置
rm -f /etc/systemd/system/{smartdns,adguardhome,dns_config_sync}.service
rm -rf /etc/smartdns /opt/AdGuardHome /etc/keepalived /opt/dnsha
systemctl daemon-reload

# 3) 删除网络 drop-in（确认当前网络不依赖它）
rm -f /etc/netplan/99-dnsha-*.yaml
netplan apply

# 4) 清理防火墙放行（如果不再需要）
iptables -D INPUT -p tcp --dport 53 -j ACCEPT
iptables -D INPUT -p udp --dport 53 -j ACCEPT
iptables -D INPUT -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save

# 5) 删除 DDNS（如果配置过）
systemctl disable --now cloudflare_ddns.timer 2>/dev/null
rm -f /etc/systemd/system/cloudflare_ddns.{service,timer}
```

如果 `install.sh --cn` 改过 apt 源，恢复备份：`cp /etc/apt/sources.list.bak /etc/apt/sources.list`；传统网络配置同理用 `/etc/network/interfaces.bak`。

## 9. 事故响应流程

1. **先确认影响面**：`dig @<VIP>` 是否可用；VIP 在哪台；两台节点 SSH 是否可达。
2. **先恢复服务，再查根因**：可切到备节点就先切（2.2），不要在故障中做复杂变更。
3. **保留现场**：切换前抓 `journalctl -u keepalived -n 200`、`tail -200 /var/log/*.log`、`ip addr`。
4. **定位**：按 [troubleshooting.md](troubleshooting.md) 的症状表。
5. **恢复后**：确认同步、配置一致、备份可用；把根因和动作写进事故记录（模板见 [CONTRIBUTING.md](../CONTRIBUTING.md#9-事故记录)）。

## 相关文档

- 症状与定位：[troubleshooting.md](troubleshooting.md)
- 配置字段：[configuration.md](configuration.md)
- 安全加固：[security.md](security.md)
