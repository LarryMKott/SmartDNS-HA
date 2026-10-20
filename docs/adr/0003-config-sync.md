# ADR-0003：配置同步用 inotify + rsync，单向主→备

- 状态：已接受
- 日期：2026-10-21
- 相关：[configuration.md](../configuration.md#7-配置同步守护进程)

## 背景

主备切换后，备节点必须拥有与主节点一致的 SmartDNS/AdGuard 配置，否则"切过去等于换了一套 DNS 行为"。可选方案：Git 仓库 + 定时拉取、配置中心、共享存储、inotify + rsync。

## 决策

在主节点运行一个 systemd 服务 `dns_config_sync`：

- `inotifywait -m -r` 监听 `/etc/smartdns` 与 `/opt/AdGuardHome/conf`。
- 文件变化（`modify/create/delete/move`）触发 `rsync -avz --delete` 到备节点同路径。
- 启动时先做一次全量同步。
- SSH 用 `BatchMode=yes`（必须免密），失败不阻塞监听。
- 源目录不存在或为空时跳过同步，避免 `--delete` 清空对端。

## 后果

**正面**

- 延迟低（秒级），配好免密后无需额外组件。
- 目录级镜像语义简单：主节点删文件，备节点也删。
- 空源保护避免了最危险的误删场景。

**负面**

- **单向**：备节点上的修改会被覆盖，无法双向合并；冲突策略就是"主节点赢"。
- 只覆盖两个目录：keepalived 配置、netplan、证书不在同步范围，需要单独维护。
- 同步只搬文件，不重载服务；切换后需要人工 `reload`/`restart`。
- 备节点上也会创建 `dns_config_sync`（`--slave-ip` 指向自身），实际无效，建议停用。
- 依赖 root 免密；`ssh-copy-id` 失败时同步静默不工作，只能靠日志发现。

## 备选方案

| 方案 | 放弃原因 |
| --- | --- |
| Git + 定时 pull | 需要人工 commit/push，延迟高，且节点上仍需处理"本地未提交修改" |
| 配置中心（etcd/Consul KV） | 引入外部依赖与额外故障域 |
| NFS/共享存储 | 单点故障时两台同时不可用，违背高可用目标 |
| 双向 syncthing | 冲突解决不可控，配置类文件不适合双向合并 |

## 证据

- `tests/docker/run.sh` 第 6、7 步：真实 rsync 同步成功；清空源目录后对端文件仍在。
- `tests/selftest.sh` 第 3、4 组：同步失败必须反映 rsync 退出码；生成的守护脚本可被解析。
