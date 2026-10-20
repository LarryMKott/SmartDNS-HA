# 配置参考

本页说明 DNSHA 生成的每个配置文件里**真正起作用**的字段、默认值，以及改完怎么生效。配置全部由脚本生成，直接改机器上的文件会在下次重跑脚本时被覆盖——长期变更请改脚本并提交 PR，或使用下文标注的"扩展点"。

## 1. 配置文件总览

| 文件 | 生成者 | 何时重写 | 扩展点 |
| --- | --- | --- | --- |
| `/etc/smartdns/smartdns.conf` | `install_dns.sh` | 每次安装/重装 | `include /etc/smartdns/conf.d/*.conf`（同步范围内，推荐） |
| `/opt/AdGuardHome/conf/AdGuardHome.yaml` | `install_dns.sh` | 每次安装/重装 | 可用 AdGuard Web 界面改，但下次重装会覆盖 |
| `/etc/keepalived/keepalived.conf` | `keepalived_config.sh` | 每次重跑 keepalived 配置 | 无（脚本全量生成） |
| `/etc/haproxy/haproxy.cfg` | `keepalived_config.sh`（haproxy 模式） | 每次重跑 | 无 |
| `/etc/consul.d/consul_server.json` | `keepalived_config.sh`（consul 模式） | 每次重跑 | 手工改后重启 consul |
| `/opt/dnsha/sync_daemon.sh` | `sync_config.sh` | 每次重跑同步配置 | 无（改脚本需同时改模板） |
| `/etc/netplan/99-dnsha-*.yaml` | `install.sh` | 每次带网络参数执行 | 可直接改，重跑会备份后覆盖 |
| `/opt/dnsha/cloudflare_ddns.sh` | `install.sh`（交互） | 重新配置 DDNS 时 | 可改，权限 700 |

> 配置同步会覆盖备节点上的 `/etc/smartdns` 与 `/opt/AdGuardHome/conf`。**不要在备节点上直接改这两个目录**——rsync `--delete` 会把你的改动删掉。

## 2. SmartDNS

### 2.1 默认生成内容

```conf
# 监听：IPv4/IPv6 双栈，TCP + UDP
bind [::]:53
bind-tcp [::]:53

# 上游分组
server 114.114.114.114 -group default
server 115.115.115.115 -group default
server 223.5.5.5 -group aliyun
server 223.6.6.6 -group aliyun
server 8.8.8.8 -group google
server 8.8.4.4 -group google

# 选路与缓存
speed-check-mode ping,tcp:80
cache-size 10000
cache-persist yes
ttl 60 3600

# 日志
log-level info
log-file /var/log/smartdns.log

# 扩展
include /etc/smartdns/conf.d/*.conf
```

### 2.2 关键字段

| 字段 | 默认值 | 作用与注意点 |
| --- | --- | --- |
| `bind` / `bind-tcp` | `[::]:53` | `[::]` 同时接受 IPv4/IPv6；改端口意味着 VIP 不再提供 53，客户端要跟着改 |
| `server` | 三组上游 | 同一个 `-group` 内的服务器参与测速选路 |
| `speed-check-mode` | `ping,tcp:80` | 按延迟选最快上游；内网禁 ICMP 时 ping 会失败，可改为只 `tcp:80` |
| `cache-size` | `10000` | 条数，不是字节 |
| `cache-persist` | `yes` | 缓存落 `/var/lib/smartdns/cache.db`，重启后仍生效 |
| `ttl` | `60 3600` | 最小/最大 TTL 裁剪区间（秒） |
| `log-level` | `info` | 排障时可临时调 `debug`，注意磁盘增长 |
| `include` | `conf.d/*.conf` | **推荐扩展点**：域名分流、上游覆盖、hosts 都写这里 |

### 2.3 常用改动示例

**换上游、按域名分流**（写到 `/etc/smartdns/conf.d/10-custom.conf`，主节点改完自动同步）：

```conf
# 国内域名走阿里，国外走 Google
domain-rules /cn/ -speed-check-mode ping -nameserver aliyun
domain-rules /com/ -nameserver google

# 内网域名交给内网 DNS
server 192.168.1.10 -group internal
domain-rules /lan/ -nameserver internal
```

**内网禁用 ICMP 时**：把 `speed-check-mode ping,tcp:80` 改成 `speed-check-mode tcp:80`，然后 `systemctl reload smartdns`。

### 2.4 生效方式

```bash
systemctl reload smartdns     # SIGHUP，重读配置，不清空缓存
systemctl restart smartdns    # 完全重启，缓存从 cache.db 恢复
dig @127.0.0.1 www.baidu.com +short   # 验证
```

## 3. AdGuard Home

### 3.1 默认生成内容（节选，字段名与 YAML 一致）

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `bind_host` / `bind_port` | `0.0.0.0` / `8080` | 管理界面，**全网可达** |
| `auth_name` / `auth_pass` | `admin` / 明文口令 | 口令来源：`ADGUARD_ADMIN_PASS` 环境变量，未设置则随机 16 位并打印；脚本写入的是明文，登录后可在管理台改密 |
| `language` | `zh-cn` | 界面语言 |
| `dns.bind_hosts` | `127.0.0.1` | 只监听本机 |
| `dns.port` | `5353` | 避免与 SmartDNS 争 53 |
| `dns.upstream_dns` | `127.0.0.1:53` | 过滤后交给 SmartDNS |
| `dns.bootstrap_dns` | `114.114.114.114` | 解析上游域名用 |
| `dns.ratelimit` | `0` | **不限速**，内网开放解析时有被放大的风险 |
| `dns.refuse_any` | `true` | 拒绝 ANY 查询，降低放大攻击面 |
| `dns.allowed_clients` | `0.0.0.0/0` | 允许所有客户端（受 bind 限制，实际只有本机） |
| `dns.cache_size` | `4194304` | 字节 |
| `dns.cache_ttl_min/max` | `60` / `86400` | 秒 |
| `dns.cache_optimistic` | `true` | 过期缓存先返回再刷新 |
| `filtering_enabled` | `true` | 启用过滤（顶层字段，不在 `dns` 下） |
| `filters` | 3 条订阅 | AdGuard DNS filter、AdAway、hpHosts |
| `schema_version` | `23` | 配置结构版本，跨版本升级时留意 |

### 3.2 端口关系（必须自洽）

```
客户端 → SmartDNS :53 → 公网
本机   → AdGuard  :5353 → 127.0.0.1:53 (SmartDNS)
```

AdGuard 的 `upstream_dns` 必须等于 SmartDNS 的监听地址，否则过滤链路断掉或形成回环。`tests/selftest.sh` 对此有一致性断言。改任一端口时，两处必须同时改。

### 3.3 生效方式

```bash
systemctl restart adguardhome
# 或走管理界面修改后由 AdGuard 自行重载
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
```

## 4. Keepalived

### 4.1 结构

```conf
global_defs {
    router_id DNSHA_MASTER
    vrrp_skip_check_adv_addr
    enable_script_security
    script_user root
}

vrrp_script check_dns_service {
    script "/etc/keepalived/check_dns.sh"
    interval 2
    weight -20
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER              # 备节点为 BACKUP
    interface eth0
    virtual_router_id 51
    priority 100              # 备节点为 90
    advert_int 1
    authentication { auth_type PASS; auth_pass dnsha123 }
    virtual_ipaddress { 192.168.1.200/24 }
    track_script { check_dns_service }
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault  "/etc/keepalived/notify.sh fault"
    notify_stop   "/etc/keepalived/notify.sh stop"
}
```

### 4.2 为什么是这些值

| 参数 | 值 | 约束 |
| --- | --- | --- |
| `state` | `MASTER` / `BACKUP` | 只能是这两个；写 `SLAVE` 会被 `keepalived -t` 判非法 |
| `priority` | 100 / 90 | 主备差 10 |
| `weight` | -20 | 绝对值必须 **大于** 优先级差（20 > 10），否则故障降权后仍可能选不出备节点 |
| `virtual_router_id` | 51 | 同一二层网络内唯一；与别的 keepalived 集群冲突会导致 VIP 乱漂 |
| `auth_pass` | `dnsha123` | keepalived 只取前 8 位；用 `VRRP_AUTH_PASS` 覆盖 |
| `advert_int` | 1s | 越小切换越快，也越容易被网络抖动误判 |
| `interval/fall/rise` | 2 / 2 / 2 | 最坏 4s 发现不健康；恢复需连续 4s 正常 |

脚本特意**没有**启用 `vrrp_strict`（与认证口令冲突）和 `vrrp_garp_interval 0`。

### 4.3 单播模式

跨网段或云环境必须用单播，否则 VRRP 组播出不去：

```conf
unicast_src_ip 192.168.1.101
unicast_peer {
    192.168.1.102
}
```

生成方式：`keepalived_config.sh ... --unicast`。注意 `deploy_dns.sh` **不会**传这个参数，必须在部署后分别到两台节点重跑一次。

### 4.4 健康检查脚本

`/etc/keepalived/check_dns.sh` 四项全过才算健康：SmartDNS active、AdGuard active、`dig @127.0.0.1 www.baidu.com` 有结果、`netstat` 能看到 `:53` 或 `:8080`。

含义：**AdGuard 挂掉也会触发切换**，即使 VIP 上的解析仍然正常。这是刻意的"整体健康"策略；如果你不希望旁路组件影响主链路，需要改 `check_dns.sh`（并同步改 `tests/selftest.sh` 的断言）。

### 4.5 生效方式

```bash
keepalived -t -f /etc/keepalived/keepalived.conf   # 先校验，有错会打印原始报错
systemctl restart keepalived
journalctl -u keepalived -n 50 --no-pager
cat /var/log/keepalived_notify.log                 # 状态迁移记录
```

## 5. Haproxy（可选模式）

```conf
frontend dns_frontend
    bind *:53
    mode tcp
    default_backend dns_backend

backend dns_backend
    mode tcp
    balance roundrobin
    server master 192.168.1.101:53 check inter 2s rise 2 fall 2
    server slave  192.168.1.102:53 check inter 2s rise 2 fall 2

listen stats
    bind 127.0.0.1:8081
    stats enable
    stats uri /haproxy-stats
    stats auth admin:<随机12位>
```

- **独占 `:53`**：本机已有服务监听时脚本拒绝写入并报错。
- stats 只监听回环，口令不打印，用 `grep 'stats auth' /etc/haproxy/haproxy.cfg` 查看。
- 该模式不绑定 VIP。

## 6. Consul（可选模式）

`/etc/consul.d/consul_server.json`：`datacenter dnsha-dc1`、`data_dir /var/lib/consul`、`node_name dnsha-<role>`、`bootstrap_expect 2`、`retry_join` 两节点、`ui true`。仅在 `command -v consul` 成功时写入；否则警告跳过。不改变 DNS 入口。

## 7. 配置同步守护进程

`/opt/dnsha/sync_daemon.sh`（由 `sync_config.sh` 生成）：

| 行为 | 细节 |
| --- | --- |
| 监控目录 | `/etc/smartdns`、`/opt/AdGuardHome/conf` |
| 事件 | `modify,create,delete,move`，忽略 `.swp/.swx/.tmp` |
| 传输 | `rsync -avz --delete`，SSH `BatchMode=yes`、`StrictHostKeyChecking=no` |
| 启动 | 先做一次全量同步，再进入监听 |
| 空源保护 | 源目录不存在或为空时跳过并记日志，避免 `--delete` 清空对端 |
| 日志 | `/var/log/dnsha_sync_daemon.log` |
| 服务 | `dns_config_sync.service`（`Restart=on-failure`） |

```bash
systemctl status dns_config_sync
tail -f /var/log/dnsha_sync_daemon.log
# 验证：主节点改文件，备节点 5 秒内应出现
echo "# probe $(date +%s)" >> /etc/smartdns/smartdns.conf
ssh root@<备节点> 'tail -1 /etc/smartdns/smartdns.conf'
```

## 8. 环境变量

| 变量 | 被谁读取 | 默认 | 用途 |
| --- | --- | --- | --- |
| `ADGUARD_ADMIN_PASS` | `install_dns.sh` | 随机 16 位 | 指定 AdGuard 管理密码；未设置则生成并打印 |
| `VRRP_AUTH_PASS` | `keepalived_config.sh` | `dnsha123` | VRRP 认证口令，只取前 8 位 |
| `HAPROXY_STATS_PASS` | `keepalived_config.sh`（haproxy） | 随机 12 位 | haproxy stats 口令 |
| `SYNC_INTERVAL` | `sync_config.sh` | 5 | 解析并打印，**当前不生效**（事件驱动，无轮询） |

> **变量作用域**：以上变量只在**执行脚本的那个 shell**里生效。通过 `ssh root@节点 '脚本'` 调用时，变量必须写在远端命令内部（`ssh root@节点 'VAR=值 /opt/dnsha/xxx.sh ...'`），本机 `export` 不会被 ssh 转发；`deploy_dns.sh` 同样不透传（见 [architecture.md](architecture.md#已知限制) L17）。

## 9. 参数优先级

`deploy_dns.sh` 的实际优先级是：

```
配置文件（--config） > 命令行参数 > 内置默认值
```

这与常见脚本相反。混用时以配置文件为准，容易"明明传了参数却不生效"，排查时先确认有没有带 `--config`。

其余脚本没有配置文件，只有命令行参数 + 环境变量 + 内置默认值。

## 10. 配置变更流程（生产）

1. 在主节点改 `/etc/smartdns/conf.d/*.conf` 或 AdGuard 配置。
2. 确认同步已推送到备节点（`tail /var/log/dnsha_sync_daemon.log`）。
3. 主节点执行对应 reload/restart，观察 `dig` 与 AdGuard 界面。
4. 在备节点**同样**执行 reload/restart（同步只搬文件，不会重启服务）。也可以先跳过，等切换后再生效，但那样切换后行为会变——不推荐。
5. 记录变更内容与回滚方式；重要变更先备份（见 [operations.md](operations.md#4-备份)）。

## 相关文档

- 安装参数：[installation.md](installation.md)
- 切换与回滚：[operations.md](operations.md)
- 安全加固：[security.md](security.md)
