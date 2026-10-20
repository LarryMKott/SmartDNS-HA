# ADR-0002：默认用 VRRP 做 VIP 漂移

- 状态：已接受
- 日期：2026-10-21
- 相关：[architecture.md](../architecture.md#故障检测与切换)

## 背景

DNS 是基础设施，客户端通常只配置一个（或两个）DNS 地址。要做到"主节点挂了客户端无感"，最直接的方式是提供一个固定 VIP，由主备节点竞争持有。备选实现包括：DNS 层负载均衡（haproxy）、服务注册发现（Consul）、以及内核级 VRRP。

## 决策

默认使用 Keepalived 的 VRRP 实例管理 VIP：

- 主节点 `priority 100`，备节点 `90`，`advert_int 1s`。
- 健康检查脚本 `check_dns.sh` 同时检查 SmartDNS、AdGuard、本机解析与端口监听，失败时 `weight -20`（`fall 2 / rise 2`，`interval 2s`）。
- 同网段用组播；跨网段/云环境用 `--unicast`。
- 保留 haproxy 与 consul 两种模式作为可选路径，但都不接管 VIP（见 [deployment.md](../deployment.md#6-三种容灾模式怎么选)）。

## 后果

**正面**

- 切换在秒级完成（进程消失约 3s，健康检查失败约 4s），不依赖外部组件。
- 客户端零改造：只认 VIP。
- 不引入额外单点（haproxy 方案需要一个 LB 节点）。

**负面**

- 要求二层可达（或单播 + 对端可达）；云网络需要额外放行协议 112。
- `virtual_router_id` 在同二层必须唯一，配置冲突会导致 VIP 乱漂。
- 需要正确设置 `weight` 与优先级差的关系，否则降权后选不出备节点；已用 `tests/selftest.sh` 断言。
- 默认开启抢占：主节点恢复后会夺回 VIP，可能造成二次抖动。需要稳定时加 `nopreempt`（脚本不生成）。

## 备选方案

| 方案 | 放弃原因 |
| --- | --- |
| haproxy 独立 LB | 多一个节点和单点；且需要独占 `:53`，与节点上的 SmartDNS 冲突 |
| Consul + DNS 接口 | 依赖外部集群；Consul DNS 的语义与递归解析器不同，不能直接替代 |
| 客户端配置双 DNS | 依赖客户端行为（多数系统只按顺序尝试），切换体验不可控 |

## 证据

- `tests/docker/run.sh` 在真实双容器网络中验证：杀主节点 keepalived → VIP 漂移 → 恢复 → 回切。
- `tests/runtime.sh` 第 4 组用 `keepalived -t` 校验生成的配置。
