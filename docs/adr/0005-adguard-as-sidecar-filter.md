# ADR-0005：AdGuard Home 作为旁路过滤层

- 状态：已接受（有已知代价）
- 日期：2026-10-21
- 相关：[architecture.md](../architecture.md#dns-查询链路默认配置)、[security.md](../security.md)

## 背景

项目同时需要"快速递归解析"（SmartDNS 的分组测速与缓存）和"广告/恶意域名过滤"（AdGuard Home 的规则引擎）。两者都能监听 53，但同一端口只能有一个进程。需要决定谁站在 `VIP:53` 上。

## 决策

- **SmartDNS 占 `:53`**，作为对外 DNS 入口与缓存/选路层。
- **AdGuard Home 监听 `127.0.0.1:5353`**，上游指向 `127.0.0.1:53`，作为可选过滤层。
- AdGuard 管理界面在 `:8080`；健康检查把 AdGuard 纳入"节点健康"判定。

## 后果

**正面**

- VIP 上的解析路径最短：客户端 → SmartDNS → 上游，AdGuard 故障不影响主链路解析。
- 过滤规则、查询日志、家长控制等能力仍可通过显式指向 `:5353` 使用。
- 端口分工清晰，不会出现两个进程抢 53 的启动竞态。

**负面（必须知道）**

- **默认不生效**：把 DNS 指向 VIP 的普通客户端**不会**经过 AdGuard，广告过滤对它们不存在。
- 组件耦合进健康检查：AdGuard 挂掉会触发 VIP 切换，即使解析仍然正常。这是为了"切换后功能完整"，但提高了切换敏感度。
- 端口关系必须自洽（AdGuard 上游 = SmartDNS 监听），改一处要改两处；`tests/selftest.sh` 对此有断言。
- 想让过滤覆盖全部客户端，需要重构入口（见下），不是改一个端口就能完成。

## 如果要让过滤覆盖全部客户端

需要一次架构变更，至少包含：

1. AdGuard 改为监听 `VIP:53`（或 `0.0.0.0:53`），SmartDNS 退到 `127.0.0.1:6053`。
2. AdGuard 的 `upstream_dns` 改为 `127.0.0.1:6053`。
3. `check_dns.sh` 的解析检查目标、`verify_deploy.sh` 的端口断言、`health_check.sh` 的端口检查同步调整。
4. `tests/selftest.sh` 的端口自洽断言改成新的映射关系。
5. 评估 AdGuard 在入口位置的吞吐与故障影响：它成为单点，必须确认其稳定性与资源占用。

在上述变更完成前，不要把"默认开启广告过滤"写进对外说明。

## 备选方案

| 方案 | 放弃原因 |
| --- | --- |
| AdGuard 占 53，SmartDNS 做上游 | AdGuard 的并发与缓存策略不如 SmartDNS 适合大流量；且过滤层成为解析单点 |
| 只保留 SmartDNS，用其域名规则过滤 | 缺少 AdGuard 的规则订阅、查询日志与家长控制能力 |
| 两个都监听不同 IP | 需要额外 IP，客户端配置复杂，VIP 语义被破坏 |

## 证据

- `install_dns.sh` 生成的 SmartDNS `bind [::]:53`、AdGuard `bind_hosts: 127.0.0.1` + `port: 5353` + `upstream_dns: 127.0.0.1:53`。
- `tests/selftest.sh` 第 6 组：DNS 链路端口自洽。
- `docs/architecture.md` 的 [L1](../architecture.md#已知限制) 明确记录该限制。
