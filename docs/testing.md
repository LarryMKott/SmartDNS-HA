# 测试与 CI

DNSHA 的验证分三层，越往下越接近真实：**静态自检**（秒级）→ **单机运行态**（容器）→ **双节点真实漂移**（Docker 网络 + 特权）。改任何脚本，至少跑第一层；改部署/keepalived/同步逻辑，跑第二层；改容灾行为，跑第三层。

## 1. 三层测试一览

| 层 | 入口 | 依赖 | 耗时 | 验证什么 |
| --- | --- | --- | --- | --- |
| 静态自检 | `bash tests/selftest.sh` | bash、grep、awk | 秒级 | 语法、断言、生成物能否被解析、安全底线、历史 bug 不再回归 |
| 运行态 | `bash tests/runtime.sh` | Debian 12 容器 + root + 特权 | 1–3 分钟 | 依赖存在、`keepalived -t`、haproxy `-c`、回滚、参数校验、同步守护、快速失败 |
| 双节点 | `bash tests/docker/run.sh` | Docker、`docker compose` | 3–5 分钟 | 真实 VRRP 单播、VIP 漂移、回切、跨机 rsync 与空源保护 |

## 2. 静态自检（`tests/selftest.sh`）

```bash
bash tests/selftest.sh
```

10 组断言（第 5 组含 5b）：

| 组 | 断言内容 | 防的是什么 |
| --- | --- | --- |
| 1 | 所有 `*.sh` 通过 `bash -n` | 语法错误提交进仓库 |
| 2 | 不用 `local` 遮蔽 `$?` | 退出码被覆盖导致"失败也报成功" |
| 3 | 同步逻辑用 rsync 自身退出码 | 管道/if 写错导致同步失败不报错 |
| 4 | `sync_config.sh` 生成的守护脚本能被 `bash -n` 解析 | 生成物语法错误到节点上才暴露 |
| 5 | keepalived `weight` 绝对值 > 主备 priority 差 | 降权后选不出备节点（见 [architecture.md](architecture.md#故障检测与切换)） |
| 5b | `state` 只能是 `MASTER`/`BACKUP` | 写 `SLAVE` 会让 keepalived 校验失败 |
| 6 | AdGuard 上游端口与 SmartDNS 监听端口自洽 | 过滤链路断开或回环 |
| 7 | `install.sh` 不覆写既有 netplan，且生成 ≥3 个 drop-in | 部署脚本破坏节点网络 |
| 8 | 历史假阳性修复不回退 | 之前修过的"测试假过"再次出现 |
| 9 | 安全底线（无弱口令等） | 默认口令倒退 |
| 10 | 5 个关键脚本有 root 权限检查 | 非 root 执行到一半失败 |

退出码 0 = 全部通过。它的价值是**把踩过的坑固化成断言**，比"看一遍代码"可靠。

## 3. 运行态测试（`tests/runtime.sh`）

在 Debian 12 容器里跑（CI 用 `debian:12`），需要 root 和真实系统工具。它用一个 `systemctl` 桩模拟服务管理，用本地 `sshd` + `dnsmasq` 模拟 DNS 与 SSH 环境。

```bash
# 与 CI（.github/workflows/runtime.yml）一致的依赖
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  curl wget git ca-certificates \
  build-essential libssl-dev \
  inotify-tools rsync sshpass \
  keepalived haproxy procps iproute2 iptables iptables-persistent \
  dnsutils net-tools \
  dnsmasq openssh-server \
  python3
bash tests/runtime.sh
```

| 组 | 验证什么 |
| --- | --- |
| 1 | 脚本声明的依赖在真实系统上都能找到（防止"只在开发机上有"） |
| 2 | `systemctl` 桩可用，脚本不会因为容器没有 systemd 而中断 |
| 3 | 本地 sshd、DNS 就绪，后续远程/解析类断言有真实对端 |
| 4 | `keepalived_config.sh` 生成配置 → `keepalived -t` 官方校验 → `check_dns.sh` 实跑 |
| 5 | haproxy 模式：`:53` 被占用时必须明确拒绝；`:53` 空闲时 `haproxy -c` 配置合法 |
| 6 | `repair_dns.sh --rollback` 在缺少默认配置时必须拒绝（不能假成功） |
| 7 | 默认配置齐备时回滚真的执行（文件被替换、服务被重启） |
| 8 | 非法参数必须失败：模式、VIP、间隔、role 等不能静默通过 |
| 9 | 同步守护脚本的状态判定与空源保护（源为空时不删对端） |
| 10 | `deploy_dns.sh` 对不可达节点快速失败（不无限等待） |

第 10 组用 `timeout` 限制。Debian 12 与 13 的 `ssh` 行为略有差异，但"快速失败"这一语义是可移植的。

> 已知盲区：`selftest.sh` 第 8 组用 `awk` 判断 `echo_error()` 是否包含 `exit 1`，属于**文本断言**，只能证明函数整体会退出，不能覆盖每个参数分支；真正的分支行为由 `runtime.sh` 第 8 组（非法参数必须失败）兜底。补参数校验时，两处都要加。

## 4. 双节点测试（`tests/docker/run.sh`）

```bash
bash tests/docker/run.sh
```

`tests/docker/compose.yml` 起两台 Debian 12 容器：

| 节点 | 地址 | 特权 |
| --- | --- | --- |
| node1 | 172.28.0.11 | `NET_ADMIN`、`NET_RAW`、`NET_BROADCAST`，`net.ipv4.ip_nonlocal_bind=1` |
| node2 | 172.28.0.12 | 同上 |

网络 `172.28.0.0/24`。`Dockerfile` 内置 `systemctl` 桩、`root:root` SSH 免密。

执行步骤：

| 步 | 动作 | 断言 |
| --- | --- | --- |
| 0 | 构建并启动双节点 | 容器就绪 |
| 1 | 网络与 SSH 就位 | 两节点互通、免密可用 |
| 2 | 生成 keepalived 配置（单播）并启动 | `keepalived -t` 通过 |
| 3 | 初始状态 | **VIP 只在 node1** |
| 4 | `pkill node1 的 keepalived` | VIP 漂到 node2 |
| 5 | 重启 node1 的 keepalived | VIP 回切到 node1（抢占生效） |
| 6 | 跑 `sync_config.sh` + 真实 rsync | 主节点文件出现在 node2 |
| 7 | 清空主节点源目录 | **node2 文件不被删除**（空源保护） |

这层是唯一能证明"切换真的发生"的测试；`selftest.sh` 只能证明"配置看起来对"。

## 5. CI

三个 workflow，全部在 push 到 `master` / PR / 手动触发时运行：

| 文件 | 名称 | 内容 |
| --- | --- | --- |
| `.github/workflows/verify.yml` | verify | 全量 `bash -n`（`*.sh` + `tests/*.sh`）→ `tests/selftest.sh` → shellcheck `-S error` 与 `-S warning` 双门禁 → style 级统计（仅报告，不阻断） |
| `.github/workflows/runtime.yml` | runtime | `debian:12` 容器装齐依赖 → 跑 `tests/runtime.sh` → 失败时导出日志 |
| `.github/workflows/docker.yml` | docker | ubuntu runner → `tests/docker/run.sh` → 失败时导出容器日志 |

门禁规则：

- `bash -n` 失败 = 阻断。
- shellcheck error / warning = 阻断。style（info）只统计，不阻断——这样既守住真问题，又不陷入无尽风格争论。
- 运行态失败 = 阻断。

本地复现 CI：

```bash
# 与 verify 等价
bash -n *.sh && bash -n tests/*.sh
bash tests/selftest.sh
shellcheck -x -S warning *.sh tests/*.sh
```

## 6. 测试覆盖不到的（要人工验证）

自动化能证明"脚本行为符合断言"，不能证明"线上一定好用"。以下必须人工确认：

- 真实网络中的 VRRP 组播/单播是否被交换机或安全组拦截。
- 真实 Debian 13 上的 `netplan` 生效结果（CI 是 12）。
- AdGuard 过滤规则是否真的拦截目标域名。
- 上游 DNS 在目标运营商网络下的延迟与可用性。
- 切换时客户端侧的实际中断时长（仓库没有性能基准）。
- IPv6 环境下的 DDNS 与 `bind [::]:53` 行为。

## 7. 加测试的规矩

1. **先能复现**：任何 bug 修复先写一个会失败的断言（静态或运行态），再修。
2. **断言要能失败**：加完故意改坏实现，确认测试变红；不会红的断言等于没写。
3. **别只测 happy path**：非法参数、缺文件、空目录、不可达主机，至少覆盖一个。
4. **同步更新文档**：测试组变化时更新本页表格。
5. **不要为了通过而放宽断言**：修实现，不改判据。若确实要调整判定，在 PR 说明里写清原因。

## 相关文档

- 架构与不变量：[architecture.md](architecture.md)
- 部署步骤：[deployment.md](deployment.md)
- 排障：[troubleshooting.md](troubleshooting.md)
