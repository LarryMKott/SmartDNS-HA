# 安装（节点初始化）

`install.sh` 只做一件事：把一台干净的 Debian 变成"可以参与 DNSHA 部署"的节点。它**不安装 DNS 服务，也不执行部署**——SmartDNS、AdGuard Home、Keepalived 由 [deployment.md](deployment.md) 阶段的 `deploy_dns.sh` 负责。

## 1. 系统要求

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 发行版 | Debian 13（trixie）及以上 | 脚本读取 `/etc/debian_version` 并校验主版本号 ≥ 13，低于此版本直接退出 |
| 权限 | root | 全程 `apt`、写 `/etc`、改网络 |
| 架构 | x86_64 / aarch64 / armv7l / armv6l | AdGuard Home 下载按 `uname -m` 映射到 amd64/arm64/armv7/armv6 |
| 内存/磁盘 | 无硬性下限；建议 ≥1 GB 内存、≥2 GB 可用磁盘 | 源码编译 SmartDNS 需要编译工具链 |
| 网络 | 能访问 Debian 源、GitHub（或 `--cn` 镜像）、AdGuard 发布页 | 首次安装依赖外网 |
| 时间 | 时钟基本准确 | 影响 TLS 与 VRRP 日志判读 |

> `--cn` 会把软件源换成中科大镜像，并把 GitHub 访问改走 `gh-proxy.org`，代码仓库改从 Gitee 镜像克隆。适用于国内网络；海外环境不要加这个参数。

## 2. 网络规划

部署前先把这张表填好，后面所有命令都用这里的值：

| 变量 | 示例 | 说明 |
| --- | --- | --- |
| `MASTER_IP` | `192.168.1.101` | 主节点地址（不要用 VIP） |
| `SLAVE_IP` | `192.168.1.102` | 备节点地址 |
| `VIP` | `192.168.1.200/24` | 对外 DNS 地址，必须与节点同网段且未被占用 |
| `INTERFACE` | `eth0` | 承载 VIP 的网卡名，两台节点保持一致 |
| `GATEWAY` | `192.168.1.1` | 节点默认网关 |

要求：

- 两台节点在同一二层网络（VRRP 组播），或部署时改用 `--unicast` 点对点模式。
- VIP 不能与任何现有设备冲突；`deploy_dns.sh`/`keepalived_config.sh` 不检测冲突。
- 接口名用 `ip -br link` 确认真实名称，不要照抄 `eth0`。

## 3. 获取脚本

```bash
# 方式一：git clone（推荐，便于后续更新）
git clone https://github.com/LarryMKott/SmartDNS-HA.git
cd SmartDNS-HA

# 方式二：下载压缩包
curl -fL -o dnsha.zip https://github.com/LarryMKott/SmartDNS-HA/archive/refs/heads/master.zip
unzip dnsha.zip && cd SmartDNS-HA-master
```

## 4. 执行 install.sh

### 4.1 参数

| 参数 | 简写 | 取值 | 作用 |
| --- | --- | --- | --- |
| `--ipv4` | `-4` | CIDR，如 `192.168.1.101/24` | 设置节点 IPv4 地址（同时写默认路由与 DNS） |
| `--gateway` | `-g` | IPv4，如 `192.168.1.1` | IPv4 默认网关，配合 `--ipv4` 使用 |
| `--ipv6` | `-6` | 地址或 `dhcp` | 配置 IPv6（静态地址或 DHCPv6） |
| `--ipv6-gateway` | `-G` | IPv6 地址 | 静态 IPv6 的网关 |
| `--interface` | `-i` | 网卡名 | 目标网卡；缺省取默认路由所在接口 |
| `--cn` | — | 无 | 切换国内镜像（apt 源 + GitHub 代理 + Gitee 克隆） |
| `--help` | `-h` | 无 | 打印用法 |

### 4.2 推荐用法（非交互）

```bash
# 主节点
sudo bash install.sh --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0

# 备节点
sudo bash install.sh --ipv4 192.168.1.102/24 --gateway 192.168.1.1 --interface eth0

# 国内网络加 --cn
sudo bash install.sh --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0 --cn
```

### 4.3 远程 `curl | bash` 的正确姿势

```bash
curl -fsSL https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh \
  | sudo bash -s -- --ipv4 192.168.1.101/24 --gateway 192.168.1.1 --interface eth0
```

**必须显式传 `--ipv4/--gateway`。** 如果不传，脚本会进入交互式网络配置并调用 `read`，而 `bash` 此时正从标准输入读取脚本内容，`read` 会把脚本后半段当成用户输入吃掉，表现为"装到一半没反应/命令乱执行"。带参数执行时不会触发交互分支。

如果确实要交互式配置，先把脚本落盘再执行：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/LarryMKott/SmartDNS-HA/master/install.sh
sudo bash install.sh
```

### 4.4 交互式会问什么

不带 `--ipv4` 且不带 `--ipv6` 时，脚本进入交互模式，依次询问：是否配置 IPv4、IPv4 地址（CIDR）、网关、是否配置 IPv6、IPv6 获取方式（DHCPv6/静态）、静态地址与网关。全部回车跳过则只做依赖与代码安装。

## 5. 脚本实际做了什么

| 阶段 | 行为 | 落盘位置 |
| --- | --- | --- |
| 1 | 校验 root、校验 Debian 主版本 ≥ 13 | — |
| 2 | `--cn`：备份并重写 apt 源为中科大 trixie 镜像，配置 git 对 GitHub 的 `insteadOf` 代理 | `/etc/apt/sources.list`（备份 `sources.list.bak`） |
| 3 | 网络：优先写 netplan drop-in，不改写已有 netplan 文件 | `/etc/netplan/99-dnsha-<iface>.yaml`、`99-dnsha-ipv6-<iface>.yaml`、`99-dnsha-ipv6-static-<iface>.yaml` |
| 4 | 无 netplan 时改写传统网络配置 | `/etc/network/interfaces`（备份 `interfaces.bak`） |
| 5 | 探测运营商出口，匹配建议上游 DNS | `/tmp/dnsha_isp.txt`、`/tmp/dnsha_isp_dns.txt` |
| 6 | `apt-get install` 依赖 | 见下节 |
| 7 | 克隆仓库到 `/opt/dnsha`（已存在则删除重建） | `/opt/dnsha/` |
| 8 | 可选：配置 Cloudflare IPv6 DDNS | `/opt/dnsha/cloudflare_ddns.sh` + systemd timer |

要点：

- **netplan 只增不改**：文件名固定为 `99-dnsha-*`；若目标文件已存在，先备份为 `<file>.bak.<时间戳>` 再写，不会覆盖你现有的 `00-installer-config.yaml`。
- **`--ipv4` 会写默认路由与 DNS**：drop-in 中同时设置 `via <网关>` 与 `nameservers 114.114.114.114 / 8.8.8.8`。如果节点原本依赖别的 DNS 做域名解析，注意这会把系统 DNS 改成公共 DNS。
- **ISP 探测只提示不生效**：脚本把运营商和推荐上游写到 `/tmp` 并打印，**不会修改** `/etc/resolv.conf`，也不会自动写入 SmartDNS 配置。需要时在 [configuration.md](configuration.md) 里手工设置上游分组。
- **`/opt/dnsha` 会被删除重建**：如果你在节点上直接改过脚本，重跑 `install.sh` 会丢失这些改动。定制请走 git 分支。

### 依赖列表

`curl wget git build-essential libssl-dev inotify-tools rsync keepalived haproxy procps iproute2 iptables-persistent dnsutils net-tools sshpass`

其中 `haproxy` 只在 haproxy 模式用到，`sshpass` 只用于密码方式的远程部署，但脚本统一安装，避免部署时才发现缺包。

## 6. 可选：Cloudflare IPv6 DDNS

安装过程末尾会询问是否配置 DDNS（可跳过）。选择配置时需要提供：

| 输入 | 说明 |
| --- | --- |
| API Token | 隐藏输入（`read -rsp`），需要有对应 Zone 的 DNS 编辑权限 |
| Zone ID | Cloudflare 控制台该域名的 Zone ID |
| 域名 | 例如 `example.com` |
| 记录名 | 例如 `dns`（最终记录为 `dns.example.com`） |

生成物：

- `/opt/dnsha/cloudflare_ddns.sh`：权限 `700`，token 以明文写在脚本内。
- `cloudflare_ddns.service`（oneshot）+ `cloudflare_ddns.timer`：开机 5 分钟后首次执行，之后每小时一次（`Persistent=true`）。
- 日志：`/var/log/cloudflare_ddns.log`；只维护 AAAA 记录，TTL 120，`proxied=false`；地址未变化时跳过更新。

阿里云 DDNS 目前是占位实现，选择后只会打印"开发中"，不会生成任何文件。

## 7. 安装后自检

```bash
# 系统与网络
cat /etc/debian_version
ip -br addr show eth0
ip route

# 代码与依赖
ls /opt/dnsha/*.sh
command -v dig rsync inotifywait keepalived sshpass

# 如果配置了 DDNS
systemctl list-timers | grep cloudflare
```

预期：`/opt/dnsha` 下有 8 个 `.sh`，所有命令都能找到路径。此阶段 `:53` 还没有服务监听，`dig` 失败是正常的——DNS 安装在部署阶段完成。

## 8. 下一步

两台节点都完成本页后，进入 [deployment.md](deployment.md) 把它们装成一套主备。

卸载与清理见 [operations.md](operations.md#8-卸载)。
