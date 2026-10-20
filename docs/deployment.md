# 部署（组成主备）

本页把两台已完成 [installation.md](installation.md) 的节点组成一套 DNS 主备集群。默认模式是 VRRP：主节点持有 VIP，故障时 VIP 漂到备节点。

## 1. 前置条件

| 检查项 | 要求 | 验证命令 |
| --- | --- | --- |
| 节点初始化 | 两台节点都已跑完 `install.sh`，`/opt/dnsha` 存在 | `ssh root@<节点> 'ls /opt/dnsha/install_dns.sh'` |
| 控制机工具 | `bash`、`ssh`、`scp`；密码方式需要 `sshpass` | `command -v ssh scp sshpass` |
| SSH 连通 | 控制机能以 root 登录两台节点；推荐免密 | `ssh -o ConnectTimeout=5 root@<节点> true` |
| 网络 | 两节点二层互通，VIP 同网段且未占用；云网络/跨网段需改用 `--unicast` | `ping <对端IP>`、`arping -D <VIP>` |
| 端口 | 节点 `:53`、`:8080` 空闲 | `ss -tuln \| grep -E ':(53\|8080)\b'` |
| 角色 | master 节点优先级 100，slave 90 | 由脚本默认值决定 |

> 控制机**不在**高可用范围内。部署完成后它只用于巡检、修复和配置下发；它宕机不影响 DNS 服务。

## 2. 一键部署

```bash
# 在仓库目录（控制机）执行
sudo ./deploy_dns.sh \
  --master-ip 192.168.1.101 \
  --slave-ip  192.168.1.102 \
  --vip       192.168.1.200/24 \
  --interface eth0
```

执行过程会写日志到控制机的 `/var/log/dnsha_deploy.log`。整条链路是串行的：SSH 测试 → 拷贝脚本 → 主节点装 DNS → 主节点配 keepalived → 主节点配同步 → 备节点装 DNS → 备节点配 keepalived → 备节点配同步 → 两台分别验证。

### 参数

| 参数 | 简写 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `--master-ip` | `-m` | 无（必填） | 主节点 IP |
| `--slave-ip` | `-s` | 无（必填） | 备节点 IP |
| `--master-pwd` | `-M` | 空 | 主节点 root 密码；为空则走免密 |
| `--slave-pwd` | `-S` | 空 | 备节点 root 密码；为空则走免密 |
| `--vip` | `-v` | `192.168.1.200/24` | 对外 VIP，**必须带掩码** |
| `--interface` | `-i` | `eth0` | VIP 绑定网卡，两台一致 |
| `--failover-mode` | `-f` | `vrrp` | `vrrp` / `haproxy` / `consul`，其他值直接报错 |
| `--config` | `-c` | 空 | 读取配置文件的路径 |
| `--help` | `-h` | — | 打印帮助 |

### 用密码而不是免密

```bash
sudo ./deploy_dns.sh -m 192.168.1.101 -s 192.168.1.102 \
  -M '<主节点root密码>' -S '<备节点root密码>' \
  -v 192.168.1.200/24 -i eth0
```

密码会进入 shell history 与进程列表。生产环境请优先配置 root 免密，或在部署后清理 history（见 [security.md](security.md#3-凭据)）。

## 3. 配置文件方式

适合把环境参数固化到仓库外的一个文件里：

```bash
# /root/dnsha.env   —— 必须是合法的 shell 赋值，等号两边不能有空格
master_ip=192.168.1.101
slave_ip=192.168.1.102
vip=192.168.1.200/24
interface=eth0
failover_mode=vrrp
master_password=
slave_password=
```

```bash
sudo ./deploy_dns.sh --config /root/dnsha.env
```

规则：

- 文件由 `source` 执行，**等号两边不能有空格**（`master_ip = x` 会被当成执行命令 `master_ip`）。
- 文件里的值**优先于命令行参数**（`read_config` 在参数解析之后执行），这与多数脚本的直觉相反：同时给出 `--vip 10.0.0.9/24` 和文件里的 `vip=192.168.1.200/24`，最终用的是文件值。
- 支持的键：`master_ip`、`slave_ip`、`master_password`、`slave_password`、`vip`、`interface`、`failover_mode`。
- 文件里写 `sync_interval` 不会生效——同步由 inotify 事件驱动，没有轮询间隔。

## 4. 部署后验收

一键部署最后一步的 `verify_deploy.sh` 失败只算**警告**，退出码不会变成非 0。所以必须单独做一次验收：

```bash
# 1) VIP 只应出现在主节点
ssh root@192.168.1.101 'ip -br addr show eth0 | grep -w 192.168.1.200'
ssh root@192.168.1.102 'ip -br addr show eth0 | grep -w 192.168.1.200 || echo "备节点未持有 VIP（正确）"'

# 2) 通过 VIP 解析（从任意内网机器）
dig @192.168.1.200 www.baidu.com +short
dig @192.168.1.200 www.qq.com +short

# 3) 管理界面
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.1.101:8080/

# 4) 双节点总体状态
./health_check.sh -m 192.168.1.101 -s 192.168.1.102 -v 192.168.1.200 --once
```

四项全过才算部署完成。任何一项失败，按 [troubleshooting.md](troubleshooting.md) 定位；不要依赖"脚本没报错"。

> `verify_deploy.sh` 可以在节点上单独重跑：
> `ssh root@192.168.1.101 '/opt/dnsha/verify_deploy.sh --vip 192.168.1.200 --role master'`
> 注意 `--vip` 这里要**纯 IP**，不带掩码。

## 5. 分步部署（推荐用于排障与定制）

一键部署会把所有参数固化在脚本调用里。要理解每一步、或者在失败后从中断处继续，按下面顺序手工执行。

### 5.1 两台节点安装 DNS 服务

```bash
# 主节点
ssh root@192.168.1.101 '/opt/dnsha/install_dns.sh --role master'
# 备节点
ssh root@192.168.1.102 '/opt/dnsha/install_dns.sh --role slave'
```

该步骤会：安装 apt 依赖 → 编译安装 SmartDNS 到 `/usr/local/sbin/smartdns` → 写 `smartdns.conf` 与 systemd 单元 → 下载 AdGuard Home → 写 `AdGuardHome.yaml` → 写 AdGuard 服务 → 放行防火墙端口。**主备配置完全相同**，`--role` 只影响日志与命名。

安装结束会打印 AdGuard 的随机管理密码，请立即记录。要固定密码，必须把环境变量写在**远端命令内部**：

```bash
ssh root@192.168.1.101 'ADGUARD_ADMIN_PASS="<自定义密码>" /opt/dnsha/install_dns.sh --role master'
ssh root@192.168.1.102 'ADGUARD_ADMIN_PASS="<自定义密码>" /opt/dnsha/install_dns.sh --role slave'
```

> 注意：`ADGUARD_ADMIN_PASS=xxx ssh ...` 这种写法**无效**（ssh 默认不传自定义环境变量），`deploy_dns.sh` 也不会把本地环境变量透传到节点。见 [architecture.md](architecture.md#已知限制) 的 L17。

### 5.2 配置 keepalived

```bash
# 主节点
ssh root@192.168.1.101 '/opt/dnsha/keepalived_config.sh \
  --role master --vip 192.168.1.200/24 --interface eth0 \
  --master-ip 192.168.1.101 --slave-ip 192.168.1.102'

# 备节点
ssh root@192.168.1.102 '/opt/dnsha/keepalived_config.sh \
  --role slave --vip 192.168.1.200/24 --interface eth0 \
  --master-ip 192.168.1.101 --slave-ip 192.168.1.102'
```

何时需要额外加参数：

| 场景 | 加什么 | 原因 |
| --- | --- | --- |
| 两节点跨网段、云上不允许组播 | `--unicast` | 生成 `unicast_src_ip`/`unicast_peer`，改用点对点通告 |
| 需要非默认优先级 | `--priority <值>` | 默认主 100 / 备 90；自行调整时保证差值 < 20（健康检查 weight 的绝对值） |
| 修改 VRRP 认证口令 | 环境变量 `VRRP_AUTH_PASS` | 默认 `dnsha123`；keepalived 只取前 8 位 |

```bash
ssh root@192.168.1.101 'VRRP_AUTH_PASS="S3cure88" /opt/dnsha/keepalived_config.sh --role master --vip 192.168.1.200/24 --interface eth0 --unicast'
```

配置完会用 `keepalived -t` 校验，非法配置会打印原始错误。校验通过后 `systemctl enable --now keepalived`。

### 5.3 配置配置同步（只需要在主节点做）

```bash
ssh root@192.168.1.101 '/opt/dnsha/sync_config.sh \
  --role master --master-ip 192.168.1.101 --slave-ip 192.168.1.102'
```

它会：安装 `inotify-tools rsync sshpass` → 若主节点没有 SSH key 则生成（RSA 2048）→ 尝试 `ssh-copy-id` 到备节点 → 生成 `/opt/dnsha/sync_daemon.sh` → 创建并启动 `dns_config_sync.service`。

`ssh-copy-id` 需要备节点密码。失败时同步不会工作，切换后配置就是旧的。部署后务必确认：

```bash
ssh root@192.168.1.101 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.1.102 true && echo OK'
ssh root@192.168.1.101 'systemctl is-active dns_config_sync'
```

`deploy_dns.sh` 也会在备节点执行一次 `sync_config.sh --role slave ...`，此时它的 `--slave-ip` 指向备节点自己，实际不会产生有效同步。备节点上的 `dns_config_sync` 可以停掉：

```bash
ssh root@192.168.1.102 'systemctl disable --now dns_config_sync'
```

### 5.4 单节点验证

```bash
ssh root@192.168.1.101 '/opt/dnsha/verify_deploy.sh --vip 192.168.1.200 --role master'
ssh root@192.168.1.102 '/opt/dnsha/verify_deploy.sh --vip 192.168.1.200 --role slave'
```

检查 9 项：SmartDNS 进程、AdGuard 进程、VIP 绑定（主有备无）、keepalived（vrrp 模式）、haproxy（haproxy 模式）、consul（consul 模式，可选）、配置同步服务（告警级）、`dig @127.0.0.1 www.baidu.com`、`:53` 与 `:8080` 监听。全过退出 0，任一失败退出 1。

## 6. 三种容灾模式怎么选

| 你的环境 | 选择 | 做法 |
| --- | --- | --- |
| 普通内网/机房，二层可达 | `vrrp`（默认） | 一键部署即可 |
| 云主机/跨网段，组播被禁 | `vrrp` + `--unicast` | 一键部署后**在两台节点上重跑** `keepalived_config.sh ... --unicast`（deploy 不传这个参数） |
| 已经有独立 LB 节点，想让 LB 按 TCP 轮询两节点 | `haproxy` | 见下节，**不要**用一键部署 |
| 只需要服务注册发现 | `consul` | 见下节；不改变 DNS 入口 |

### haproxy 模式：独立 LB 节点

haproxy 配置要求**独占 `:53`**，而节点上 SmartDNS 已经占用 `:53`，所以 `deploy_dns.sh --failover-mode haproxy` 一定会在两台节点上报错：

```
haproxy 模式需要独占 :53，但本机已有服务监听（smartdns/AdGuard）。
请改用 vrrp 模式，或先把 DNS 入口迁到 127.0.0.1:6053
```

正确做法是在第三台机器（LB）上执行：

```bash
# LB 节点：先把仓库脚本拷过去
scp -r ./* root@192.168.1.103:/opt/dnsha/
ssh root@192.168.1.103 '/opt/dnsha/keepalived_config.sh \
  --role master --failover-mode haproxy \
  --master-ip 192.168.1.101 --slave-ip 192.168.1.102 \
  --interface eth0 --vip 192.168.1.200/24'
```

注意：

- 该模式的 haproxy 配置会生成 `frontend dns_frontend bind *:53` + `backend` 两台上游 + `listen stats 127.0.0.1:8081`。
- 脚本**不会**给 LB 节点绑定 VIP；客户端要指向 LB 的地址，VIP 需要另外的方案。
- haproxy stats 口令随机生成且不打印，用 `grep 'stats auth' /etc/haproxy/haproxy.cfg` 查看。

### consul 模式

```bash
ssh root@<节点> '/opt/dnsha/keepalived_config.sh --role master --failover-mode consul --master-ip ... --slave-ip ... --vip ... --interface eth0'
```

- 仅在节点**已安装 consul** 时写 `/etc/consul.d/consul_server.json`（`bootstrap_expect 2`、`retry_join` 两节点、开启 UI）并重启服务；未安装则打印警告并跳过。
- 不接管 VIP，不改变 DNS 入口；`verify_deploy.sh --failover-mode consul` 中 consul 检查是可选项。
- `bind_addr` 取 `hostname -I` 的第一个地址，多网卡环境请人工核对。

## 7. 重跑与失败恢复

- **幂等性**：`deploy_dns.sh` 可重复执行，会重新装服务、重写配置、重启 keepalived/同步。AdGuard 密码每次重装都会重新生成（`deploy_dns.sh` 不透传 `ADGUARD_ADMIN_PASS`，需要固定密码时按 5.1 在节点上以远端内联环境变量重装）。
- **部署中断**：日志在 `/var/log/dnsha_deploy.log`，按"分步部署"从失败的那一步继续，不要从头盲跑。
- **keepalived 配置报错**：`ssh root@<节点> 'keepalived -t -f /etc/keepalived/keepalived.conf'` 看原始错误。
- **回滚**：`repair_dns.sh --rollback` 需要节点上存在三份默认配置，仓库不会生成它们。首次部署成功后请手工备份：

```bash
ssh root@192.168.1.101 'cp /etc/smartdns/smartdns.conf /opt/dnsha/smartdns_default.conf; \
  cp /opt/AdGuardHome/conf/AdGuardHome.yaml /opt/dnsha/adguard_default.yaml; \
  cp /etc/keepalived/keepalived.conf /opt/dnsha/keepalived_default.conf'
```

之后才能执行：

```bash
sudo ./repair_dns.sh -m 192.168.1.101 -s 192.168.1.102 --rollback
```

## 8. 部署完成检查单

- [ ] 主节点 `ip -br addr` 能看到 VIP，备节点看不到
- [ ] `dig @<VIP>` 能解析至少两个域名
- [ ] `http://<节点>:8080` 返回 200，AdGuard 密码已记录
- [ ] `health_check.sh --once` 显示整体 `healthy`
- [ ] 主节点到备节点 root 免密可用，`dns_config_sync` 为 `active`
- [ ] 修改 `/etc/smartdns/smartdns.conf` 后，备节点对应文件 5 秒内变化
- [ ] 已备份三份默认配置（若要使用回滚）
- [ ] 已按 [security.md](security.md) 完成口令与暴露面加固

## 相关文档

- 配置字段详解：[configuration.md](configuration.md)
- 切换与巡检：[operations.md](operations.md)
- 部署失败：[troubleshooting.md](troubleshooting.md)
