# 安全

本页写清三件事：DNSHA 信任谁、暴露了什么、怎么收敛。默认配置面向**可信内网**；直接放到公网会出问题，原因如下。

## 1. 信任模型

| 主体 | 被信任的程度 | 凭据 |
| --- | --- | --- |
| 控制机 | 完全信任：可 root 登录两台节点，可改一切配置 | SSH key / root 密码 |
| 节点之间 | 完全信任：主 → 备 root 免密，rsync 覆盖配置 | SSH key |
| 内网客户端 | 只应发 DNS 查询 | 无 |
| 同二层网络的主机 | 可参与/伪造 VRRP 通告 | VRRP 认证口令（8 位） |
| 公网 | 不应可达 | — |

结论：**控制机与节点间的 root SSH 是最关键的资产**，一旦丢失等于整套 DNS 被接管。

## 2. 资产与风险

| 资产 | 位置 | 风险 |
| --- | --- | --- |
| DNS 解析可用性 | VIP `:53` | 被 DDoS / 被投毒 / 被开放递归放大利用 |
| AdGuard 管理台 | 节点 `:8080` | 弱口令 → 改过滤规则、改上游、看查询日志 |
| root SSH | 控制机 ↔ 节点 | 失守 → 全量接管 |
| VRRP 认证口令 | `keepalived.conf` | 同网段可伪造通告抢 VIP（中间人/劫持解析） |
| AdGuard 管理口令 | `AdGuardHome.yaml` | 文件泄露即可直接登录 |
| Cloudflare Token | `/opt/dnsha/cloudflare_ddns.sh`（700） | 可改该域名 DNS 记录 |
| 查询日志 | AdGuard / SmartDNS 日志 | 泄露内网访问画像 |

## 3. 凭据

| 凭据 | 默认 | 存放 | 轮换方式 |
| --- | --- | --- | --- |
| VRRP 认证 | `dnsha123`（只取前 8 位） | `/etc/keepalived/keepalived.conf` | 在节点上以内联 `VRRP_AUTH_PASS=<新值>` 重跑 `keepalived_config.sh`（两台都要） |
| AdGuard 管理密码 | 每次随机 16 位并打印 | `AdGuardHome.yaml` 的 `auth_pass`（脚本写入明文） | `ADGUARD_ADMIN_PASS=<新值>` 重装，或管理台改密 |
| haproxy stats | 随机 12 位，不打印 | `/etc/haproxy/haproxy.cfg` | 重跑 haproxy 配置 |
| Cloudflare API Token | 用户输入 | `cloudflare_ddns.sh` 明文 | 重新配置 DDNS 或直接编辑脚本 |
| root SSH | 用户自备 | `~/.ssh/authorized_keys` | 换 key 并回收旧 key |

生成时就把口令钉住（**必须写在远端命令内部**，ssh 不会转发本地环境变量）：

```bash
# 两台节点，各自执行
ssh root@192.168.1.101 'VRRP_AUTH_PASS="<8位随机>" /opt/dnsha/keepalived_config.sh --role master --vip <VIP/CIDR> --interface <网卡>'
ssh root@192.168.1.101 'ADGUARD_ADMIN_PASS="<强口令>" /opt/dnsha/install_dns.sh --role master'
```

`deploy_dns.sh` 只负责编排，不会透传这两个变量；用一键部署时口令会按脚本默认/随机生成，部署后再按上面方式重跑对应节点脚本即可。

## 4. 暴露面

| 端口 | 默认监听 | 谁能访问 | 建议 |
| --- | --- | --- | --- |
| 53/tcp+udp | `[::]:53` | 取决于网络；脚本放行全部来源 | 只允许内网网段；公网入口前面加清洗/限速 |
| 8080/tcp | `0.0.0.0` | 全网可达（脚本放行全部来源） | 限制来源 IP，或改成只监听管理网卡 |
| 5353 | `127.0.0.1` | 仅本机 | 保持 |
| 22/tcp | sshd | 取决于 sshd 配置 | 限制来源、禁密码登录 |
| 112（VRRP） | 节点间 | 同二层 | 网络侧限制，或改单播 |
| 8081 | `127.0.0.1` | 仅本机（haproxy 模式） | 保持 |

脚本的防火墙动作是**追加 ACCEPT**，不会收紧默认策略。如果系统默认策略是 DROP，还需要显式放行 SSH 与 VRRP，否则会把自己锁在外面。

## 5. 加固清单

按优先级从高到低：

### P0 — 上线前必须做

- [ ] **换掉默认 VRRP 口令**：`VRRP_AUTH_PASS` 设为 8 位随机值，两台一致。
- [ ] **固定 AdGuard 强口令**：`ADGUARD_ADMIN_PASS`，不要用安装时随机生成后丢失的方式。
- [ ] **收紧 AdGuard 配置文件权限**：
  ```bash
  chmod 600 /opt/AdGuardHome/conf/AdGuardHome.yaml
  chmod 700 /opt/AdGuardHome
  ```
- [ ] **限制 8080 来源**（示例：只允许管理网段）：
  ```bash
  iptables -I INPUT -p tcp --dport 8080 ! -s 192.168.1.0/24 -j DROP
  netfilter-persistent save
  ```
- [ ] **SSH 禁密码、限来源**：`/etc/ssh/sshd_config` 设 `PermitRootLogin prohibit-password`、`PasswordAuthentication no`，并配 `AllowUsers root@<控制机IP>`。
- [ ] **删掉命令行里的密码**：部署后 `history -c`，改用免密。

### P1 — 一周内

- [ ] **限制开放递归**：SmartDNS 只对内网提供解析；公网侧用安全组/防火墙限源，或在上游加 ACL。
- [ ] **确认 `refuse_any` 与限速**：默认已 `refuse_any: true`、`ratelimit: 0`。若必须对内网开放，考虑设 `ratelimit` 上限，降低被反射放大的风险。
- [ ] **收紧 VRRP**：同二层只允许两台节点发 VRRP；能单播就单播。
- [ ] **备份加密**：备份包含口令与 hash，`gpg` 或加密卷存放。
- [ ] **Cloudflare Token 最小权限**：只给目标 Zone 的 DNS 编辑，不给全局 Key。

### P2 — 持续

- [ ] 关注 Debian 安全更新、SmartDNS/AdGuard/keepalived 版本公告。
- [ ] 定期轮换口令（季度）。
- [ ] 审计 `authorized_keys`，清理离职/临时 key。
- [ ] 检查日志里是否误打印口令（`grep -i 'pass\|token' /var/log/dnsha*.log`）。

## 6. 已知安全弱点（如实列出）

| # | 弱点 | 影响 | 缓解 |
| --- | --- | --- | --- |
| S1 | VRRP 认证是明文口令，仅 8 位 | 同网段可伪造通告 | 换强口令 + 网络隔离 + 单播 |
| S2 | AdGuard 密码以明文写入 `auth_pass` | 文件或备份泄露即可直接登录 | `chmod 600` + 强口令 + 备份加密 |
| S3 | 8080 默认全网监听 | 管理台暴露 | 防火墙限源 / 改监听地址 |
| S4 | `:53` 无 ACL，开放递归 | 被用作 DNS 放大器 | 网络侧限源；必要时加 `ratelimit` |
| S5 | 部署支持命令行密码 | 进 history / `ps` | 免密 + 清理 history |
| S6 | Cloudflare Token 明文存脚本 | 脚本泄露即 token 泄露 | 权限 700 + 最小权限 token |
| S7 | 无配置审计与签名 | 无法证明配置未被篡改 | 定期 diff 主备 + 备份校验 |
| S8 | SmartDNS 从 master 编译 | 供应链不可复现 | 固定 commit + 校验来源 |
| S9 | 日志可能含查询域名 | 隐私泄露 | 限制日志访问权限，缩短保留期 |

## 7. 安全事件处置

1. **隔离**：把节点从网络摘除或在防火墙封禁 53/8080/22。
2. **止损**：停 `keepalived` 让 VIP 只落在一台可信节点；停 `adguardhome` 切断管理面。
3. **取证**：保存 `journalctl`、`/var/log/*`、`authorized_keys`、配置文件的副本（不要先清日志）。
4. **轮换**：VRRP 口令、AdGuard 密码、Cloudflare Token、SSH key 全部更换。
5. **复盘**：按 [CONTRIBUTING.md](../CONTRIBUTING.md#9-事故记录) 记录根因与改进项。

## 8. 报告漏洞

请不要在公开 issue 中贴出可直接利用的细节（口令、Token、完整攻击链）。优先使用 GitHub 的 Security Advisory（仓库 → Security → Report a vulnerability），或在 issue 中只描述影响面并请求私下沟通。

## 相关文档

- 架构与信任边界：[architecture.md](architecture.md#暴露面与信任边界)
- 配置项：[configuration.md](configuration.md)
- 运维与备份：[operations.md](operations.md#4-备份)
