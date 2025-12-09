# DNSHA

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Script-89e051.svg)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/OS-Debian%2013+-blue.svg)](https://www.debian.org/)

DNSHA 是一款**纯Shell实现**的DNS主备容灾一键部署系统，基于 SmartDNS + AdGuard Home 构建高可用DNS服务，支持 VRRP/Haproxy/Consul 三种容灾模式，具备秒级VIP漂移、实时配置同步、全链路健康监控能力，核心优势是**轻量级、零配置复杂度、纯原生Shell实现**，无Python/Windows依赖，适配Debian服务器自动化运维场景。

## 🌟 核心特性
- **纯Shell实现**：仅依赖Linux原生工具（bash/ssh/rsync等），无任何外部语言依赖，部署包<100KB；
- **一键部署**：单脚本完成主备节点的DNS服务安装、容灾配置、VIP绑定、配置同步全流程；
- **多容灾模式**：支持 VRRP（默认，秒级VIP漂移）、Haproxy（负载均衡）、Consul（服务发现）三种模式；
- **实时配置同步**：基于 inotify + rsync 实现主备节点配置实时同步，延迟<1秒；
- **全链路监控**：内置健康检查脚本，实时监控服务状态、VIP绑定、DNS解析、同步服务；
- **故障自愈**：提供一键修复/配置回滚工具，支持DNS服务、容灾服务、同步服务快速恢复；
- **高性能**：单节点支持10000 QPS，VIP切换延迟<3秒，符合生产级性能要求。

## 📋 前置条件
### 环境要求
| 节点类型       | 系统版本       | 硬件要求       | 权限要求 |
|----------------|----------------|----------------|----------|
| 主/备节点      | Debian 13+     | CPU ≥1核，内存 ≥512MB | root     |
| 部署节点       | 任意Linux系统  | 无特殊要求     | root     |

### 网络要求
- 主/备/部署节点网络互通，开放以下端口：
  - 22（SSH）：用于脚本部署和远程执行；
  - 53（TCP/UDP）：DNS解析服务；
  - 8080（TCP）：AdGuard Home Web管理；
  - 11211（TCP/UDP，可选）：Consul模式服务发现；
- 主备节点支持SSH登录（优先免密，也可使用密码）。

## 🚀 快速开始
### 1. 一键安装（推荐）

#### 国内用户（推荐使用国内加速）
```bash
# 国内加速安装（使用ghproxy.com加速GitHub访问）
curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- --cn

# 国内加速+固定IPv4配置
curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- --cn \
  --ipv4 192.168.1.100/24 --gateway 192.168.1.1

# 国内加速+IPv4+IPv6配置
curl -fsSL https://ghproxy.com/https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- --cn \
  --ipv4 192.168.1.100/24 --gateway 192.168.1.1 \
  --ipv6 2001:db8::1/64 --ipv6-gateway 2001:db8::fffe
```

#### 国际用户
```bash
# 直接使用curl安装（支持自动检测当地运营商DNS）
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash

# 设置固定IPv4地址
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- \
  --ipv4 192.168.1.100/24 --gateway 192.168.1.1

# 设置IPv4+IPv6地址
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- \
  --ipv4 192.168.1.100/24 --gateway 192.168.1.1 \
  --ipv6 2001:db8::1/64 --ipv6-gateway 2001:db8::fffe

# 指定网卡并设置IP
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh | bash -s -- \
  --interface eth1 \
  --ipv4 192.168.1.100/24 --gateway 192.168.1.1
```

### 2. 手动下载脚本包
```bash
# 创建脚本目录并进入
mkdir -p /opt/dnsha && cd /opt/dnsha

# 下载所有核心脚本
git clone https://github.com/LarryMKott/SmartDNS-HA.git .

# 赋予执行权限
chmod +x *.sh
```

### 2. 一键部署
#### 方式1：命令行参数部署（推荐）
```bash
# VRRP模式（默认，秒级VIP漂移）
./deploy_dns.sh \
  --master-ip 192.168.1.100 \  # 主节点IP（必填）
  --slave-ip 192.168.1.101 \   # 备节点IP（必填）
  --master-pwd your-root-pwd \ # 主节点root密码（免密可省略）
  --slave-pwd your-root-pwd \  # 备节点root密码（免密可省略）
  --vip 192.168.1.200/24 \     # 虚拟IP（默认192.168.1.200/24）
  --interface eth0             # 网卡名称（默认eth0）

# Haproxy模式（负载均衡）
./deploy_dns.sh \
  --master-ip 192.168.1.100 \
  --slave-ip 192.168.1.101 \
  --failover-mode haproxy

# Consul模式（服务发现）
./deploy_dns.sh \
  --master-ip 192.168.1.100 \
  --slave-ip 192.168.1.101 \
  --failover-mode consul
```

#### 方式2：配置文件部署
```bash
# 1. 创建配置文件
cat > dnsha.conf << EOF
master_ip = 192.168.1.100
slave_ip = 192.168.1.101
master_password = your-root-pwd
slave_password = your-root-pwd
failover_mode = vrrp
vip = 192.168.1.200/24
interface = eth0
sync_interval = 1
EOF

# 2. 执行部署
./deploy_dns.sh --config dnsha.conf
```

### 3. 验证部署
```bash
# 一键验证部署结果（仅检查一次）
./health_check.sh \
  --master-ip 192.168.1.100 \
  --slave-ip 192.168.1.101 \
  --vip 192.168.1.200 \
  --once
```

## 📖 详细使用指南
### 核心脚本说明
| 脚本名称          | 功能描述                                  | 核心参数                                                                 |
|-------------------|-------------------------------------------|--------------------------------------------------------------------------|
| `deploy_dns.sh`   | 一键部署主备节点（核心入口）              | `--master-ip`/`--slave-ip`/`--failover-mode`/`--config`                  |
| `health_check.sh` | 实时监控节点状态                          | `--master-ip`/`--slave-ip`/`--interval`/`--once`                         |
| `repair_dns.sh`   | 故障修复/配置回滚                         | `--master-ip`/`--slave-ip`/`--dns`/`--failover`/`--rollback`             |
| `verify_deploy.sh`| 验证单个节点部署结果                      | `--vip`/`--role`（master/slave）                                         |

### 实时监控
```bash
# 循环监控（每5秒刷新，按Ctrl+C退出）
./health_check.sh -m 192.168.1.100 -s 192.168.1.101 -i 5

# 仅检查一次
./health_check.sh -m 192.168.1.100 -s 192.168.1.101 -o
```

### 故障修复
```bash
# 全量修复（DNS+容灾+同步服务）
./repair_dns.sh -m 192.168.1.100 -s 192.168.1.101

# 仅修复DNS服务
./repair_dns.sh -m 192.168.1.100 -s 192.168.1.101 -d

# 仅修复容灾服务（Keepalived/Haproxy/Consul）
./repair_dns.sh -m 192.168.1.100 -s 192.168.1.101 -f

# 配置回滚到默认版本
./repair_dns.sh -m 192.168.1.100 -s 192.168.1.101 -r
```

## 🧪 测试计划
### 功能测试
```bash
# 1. 验证DNS服务运行
ssh root@192.168.1.100 "pgrep -f smartdns && pgrep -f AdGuardHome"

# 2. 验证VIP绑定（主节点应绑定）
ssh root@192.168.1.100 "ip addr | grep 192.168.1.200"

# 3. 验证配置同步（修改主节点配置，备节点应同步）
ssh root@192.168.1.100 "echo 'test' >> /etc/smartdns/test.conf"
sleep 2
ssh root@192.168.1.101 "cat /etc/smartdns/test.conf | grep test"

# 4. 验证容灾切换（停止主节点Keepalived，备节点绑定VIP）
ssh root@192.168.1.100 "systemctl stop keepalived"
sleep 3
ssh root@192.168.1.101 "ip addr | grep 192.168.1.200"

# 5. 故障恢复（重启主节点，VIP切回）
ssh root@192.168.1.100 "systemctl start keepalived"
sleep 3
ssh root@192.168.1.100 "ip addr | grep 192.168.1.200"
```

### 压力测试
```bash
# 安装dnsperf
apt install -y dnsperf

# 模拟10000 QPS查询，验证响应时间（目标VIP：192.168.1.200）
dnsperf -d /usr/share/dnsperf/test.dns -s 192.168.1.200 -Q 10000 -l 60
```

## 🛠️ 日常运维
### 日志查看
```bash
# 主节点配置同步日志
ssh root@192.168.1.100 "tail -f /var/log/dns_config_sync.log"

# Keepalived日志（VRRP模式）
ssh root@192.168.1.100 "journalctl -u keepalived -f"

# SmartDNS日志
ssh root@192.168.1.100 "tail -f /var/log/smartdns.log"
```

### 手动切换主备
```bash
# 主节点降级（停止Keepalived，VIP漂移到备节点）
ssh root@192.168.1.100 "systemctl stop keepalived"

# 备节点升级（手动启动Keepalived，抢占VIP）
ssh root@192.168.1.101 "systemctl restart keepalived"
```

## ❓ 常见问题
| 问题现象                | 排查/解决方法                                                                 |
|-------------------------|------------------------------------------------------------------------------|
| VIP无法绑定             | 1. 检查网卡名称是否正确（`ip link`）；<br>2. 查看Keepalived日志：`journalctl -u keepalived`；<br>3. 确认VIP网段与网卡一致。 |
| 配置不同步              | 1. 检查主节点同步服务状态：`systemctl status dns_config_sync`；<br>2. 查看同步日志：`tail -f /var/log/dns_config_sync.log`；<br>3. 确认主备节点SSH免密互通。 |
| DNS解析失败             | 1. 检查SmartDNS/AdGuard进程：`pgrep -f smartdns && pgrep -f AdGuardHome`；<br>2. 查看SmartDNS日志：`tail -f /var/log/smartdns.log`；<br>3. 验证端口占用：`netstat -tulpn | grep 53`。 |
| Consul服务无法启动      | 1. 检查Consul配置：`cat /etc/consul.d/consul_server.json`；<br>2. 手动启动排查：`consul agent -dev -client 0.0.0.0`。 |
| Haproxy负载均衡异常     | 1. 查看Haproxy日志：`cat /var/log/haproxy.log`；<br>2. 验证后端节点：`haproxy -c -f /etc/haproxy/haproxy.cfg`。 |

## 🚀 扩展方向
1. **多云适配**：集成阿里云/腾讯云SDK，自动获取节点IP、配置安全组；
2. **监控集成**：输出Prometheus指标，对接Grafana实现可视化监控；
3. **批量部署**：支持多组主备节点批量部署，适配大型集群；
4. **AI异常检测**：基于Shell+awk分析DNS日志，识别异常查询流量；
5. **Web管理界面**：可选轻量Go/Python Web服务，提供可视化操作界面。

## 📄 许可证
本项目基于 MIT 许可证开源，详情请见 [LICENSE](LICENSE) 文件。

## 📞 贡献与反馈
- 提交Issue：请描述清晰问题现象、复现步骤、环境信息；
- 提交PR：请遵循Shell脚本规范（缩进2空格、注释清晰），并附带测试用例；
- 技术支持：可通过Issues或邮件（xxx@xxx.com）反馈问题。

## 📖 参考文档
- [SmartDNS 官方文档](https://pymumu.github.io/smartdns/)
- [AdGuard Home 官方文档](https://github.com/AdguardTeam/AdGuardHome/wiki)
- [Keepalived 官方文档](https://keepalived.readthedocs.io/)
- [Consul 官方文档](https://developer.hashicorp.com/consul/docs)