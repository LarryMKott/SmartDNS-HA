#!/usr/bin/env bash
# 双节点 Docker 运行态验证：真 VIP 漂移 + 真跨主机 rsync
# 在 GitHub Actions runner（宿主机）上运行，需要 docker 与 compose v2
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

COMPOSE=(docker compose -f tests/docker/compose.yml)
pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
dc()  { "${COMPOSE[@]}" "$@"; }

dump_logs() {
    echo "----- compose ps -----"
    dc ps || true
    echo "----- node1 keepalived -----"
    dc exec -T node1 bash -c 'tail -30 /tmp/ka.log 2>/dev/null' || true
    echo "----- node1 config -----"
    dc exec -T node1 bash -c 'cat /etc/keepalived/keepalived.conf 2>/dev/null' || true
    echo "----- node1 addrs -----"
    dc exec -T node1 bash -c 'ip -4 addr' || true
    echo "----- node2 addrs -----"
    dc exec -T node2 bash -c 'ip -4 addr' || true
}

cleanup() {
    if (( fail > 0 )); then
        dump_logs
    fi
    dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== 0. 构建并启动双节点 =="
if dc up -d --build >/tmp/compose_up.log 2>&1; then
    ok "docker compose up 成功"
else
    bad "docker compose up 失败（见 /tmp/compose_up.log）"
    exit 1
fi
sleep 5

echo "== 1. 两节点网络与 SSH 就位 =="
for n in node1 node2; do
    if dc exec -T "$n" bash -c 'ip -4 addr show eth0' >/dev/null 2>&1; then
        ok "$n 的 eth0 可用"
    else
        bad "$n 的 eth0 不可用"
    fi
    dc exec -T "$n" bash -c 'mkdir -p /run/sshd; ssh-keygen -A >/dev/null 2>&1; /usr/sbin/sshd' >/dev/null 2>&1
done
sleep 2
dc exec -T node1 bash -c 'ssh-keygen -q -t rsa -b 2048 -N "" -f /root/.ssh/id_rsa 2>/dev/null || true'
if dc exec -T node1 bash -c 'sshpass -p root ssh-copy-id -o StrictHostKeyChecking=no root@172.28.0.12' >/dev/null 2>&1; then
    ok "node1 → node2 免密登录建立"
else
    bad "node1 → node2 免密登录失败"
fi

echo "== 2. 生成并启动 keepalived（VRRP 单播）=="
dc exec -T node1 bash -c './keepalived_config.sh --role master --vip 172.28.0.100/24 --interface eth0 --master-ip 172.28.0.11 --slave-ip 172.28.0.12 --unicast --failover-mode vrrp' >/tmp/ka1.log 2>&1
dc exec -T node2 bash -c './keepalived_config.sh --role slave --vip 172.28.0.100/24 --interface eth0 --master-ip 172.28.0.11 --slave-ip 172.28.0.12 --unicast --failover-mode vrrp' >/tmp/ka2.log 2>&1
if dc exec -T node1 bash -c 'grep -q unicast_peer /etc/keepalived/keepalived.conf'; then
    ok "生成的配置含 unicast_peer"
else
    bad "生成的配置缺 unicast_peer"
fi
if dc exec -T node1 bash -c 'keepalived -t -f /etc/keepalived/keepalived.conf'; then
    ok "keepalived -t 通过"
else
    bad "keepalived -t 失败"
fi
dc exec -T -d node1 bash -c 'keepalived -n -l -f /etc/keepalived/keepalived.conf >/tmp/ka.log 2>&1'
dc exec -T -d node2 bash -c 'keepalived -n -l -f /etc/keepalived/keepalived.conf >/tmp/ka.log 2>&1'
sleep 8

echo "== 3. 主节点持有 VIP，备节点不持有 =="
if dc exec -T node1 bash -c "ip -4 addr show eth0 | grep -q '172.28.0.100/24'"; then
    ok "主节点持有 VIP"
else
    bad "主节点没有 VIP"
fi
if dc exec -T node2 bash -c "ip -4 addr show eth0 | grep -q '172.28.0.100/24'"; then
    bad "备节点意外持有 VIP"
else
    ok "备节点未持有 VIP"
fi

echo "== 4. 杀掉主节点 keepalived → VIP 必须漂到备节点 =="
dc exec -T node1 bash -c 'pkill -x keepalived || true' >/dev/null 2>&1
sleep 10
if dc exec -T node2 bash -c "ip -4 addr show eth0 | grep -q '172.28.0.100/24'"; then
    ok "VIP 已漂移到备节点"
else
    bad "VIP 没有漂移（核心功能失效）"
fi

echo "== 5. 恢复主节点 → VIP 应回切 =="
dc exec -T -d node1 bash -c 'keepalived -n -l -f /etc/keepalived/keepalived.conf >/tmp/ka.log 2>&1'
sleep 10
if dc exec -T node1 bash -c "ip -4 addr show eth0 | grep -q '172.28.0.100/24'"; then
    ok "VIP 回切到主节点"
else
    bad "VIP 未回切（优先级或抢占配置有问题）"
fi

echo "== 6. 跨主机配置同步（真 rsync）=="
dc exec -T node1 bash -c './sync_config.sh --role master --master-ip 172.28.0.11 --slave-ip 172.28.0.12' >/tmp/sync1.log 2>&1
dc exec -T node1 bash -c 'mkdir -p /etc/smartdns && printf "docker-sync-test\n" > /etc/smartdns/docker-test.conf'
dc exec -T node1 bash -c 'timeout 12 bash /opt/dnsha/sync_daemon.sh' >/tmp/daemon.log 2>&1
if dc exec -T node2 bash -c 'grep -q docker-sync-test /etc/smartdns/docker-test.conf 2>/dev/null'; then
    ok "文件已跨主机同步到 node2"
else
    bad "跨主机同步失败（node2 没收到文件）"
fi

echo "== 7. 源目录清空时不得删除对端文件 =="
dc exec -T node1 bash -c 'rm -rf /etc/smartdns/*'
dc exec -T node1 bash -c 'timeout 12 bash /opt/dnsha/sync_daemon.sh' >/tmp/daemon2.log 2>&1
if dc exec -T node2 bash -c 'test -f /etc/smartdns/docker-test.conf'; then
    ok "对端文件未被 --delete 清掉（空源保护生效）"
else
    bad "对端文件被删除了（--delete 保护失效）"
fi

echo
echo "================ Docker 双节点汇总 ================"
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"
if (( fail > 0 )); then
    echo "Docker 双节点验证失败"
    exit 1
fi
echo "Docker 双节点验证全部通过"
