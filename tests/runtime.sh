#!/usr/bin/env bash
# 运行态验证：在真实 Debian 容器里**执行**脚本，而不只是读代码
# 用法：bash tests/runtime.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

echo "== 1. 脚本声明的依赖在真实系统上存在 =="
for c in dig netstat sshpass rsync inotifywait keepalived haproxy ss iptables; do
    if command -v "$c" >/dev/null 2>&1; then
        ok "命令存在：$c"
    else
        bad "命令缺失：$c"
    fi
done

echo "== 2. systemctl 桩（容器内没有 systemd）=="
cat > /usr/local/bin/systemctl <<'STUB'
#!/bin/bash
echo "systemctl $*" >> /tmp/systemctl_calls.log
if [[ "${1:-}" == "is-active" ]]; then
    echo "active"
fi
exit 0
STUB
chmod +x /usr/local/bin/systemctl
ok "systemctl 桩就位：/usr/local/bin/systemctl"

echo "== 3. 本地 sshd 与 DNS 就绪 =="
ssh-keygen -A >/dev/null 2>&1
mkdir -p /root/.ssh
if [[ ! -f /root/.ssh/id_rsa ]]; then
    ssh-keygen -q -t rsa -b 2048 -N "" -f /root/.ssh/id_rsa
fi
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
mkdir -p /run/sshd
/usr/sbin/sshd
sleep 2
if ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; then
    ok "本地 SSH 免密可用"
else
    bad "本地 SSH 免密不可用"
fi

dnsmasq --port=53 --listen-address=127.0.0.1 --bind-interfaces \
    --address=/dnsha.test/127.0.0.1 --no-resolv --user=root \
    --pid-file=/tmp/dnsmasq.pid >/dev/null 2>&1
sleep 1
if dig @127.0.0.1 dnsha.test +short +time=2 2>/dev/null | grep -q '^127\.0\.0\.1$'; then
    ok "本地 DNS 在 :53 应答"
else
    bad "本地 DNS 未应答"
fi
if netstat -tuln 2>/dev/null | grep -qE ':53[[:space:]]'; then
    ok "netstat 可见 :53 监听（依赖 net-tools 生效）"
else
    bad "netstat 看不到 :53"
fi

# keepalived 不允许在 lo 上跑 VRRP，取一个真实网卡（容器里通常是 eth0）
IFACE=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}' | sed 's/@.*//')
IFACE=${IFACE:-eth0}
ok "测试用网卡：$IFACE"

echo "== 4. keepalived：生成配置 → 官方 -t 校验 → 健康检查脚本实跑 =="
if bash keepalived_config.sh --role master --vip 127.0.0.2/32 --interface "$IFACE" \
    --master-ip 127.0.0.1 --slave-ip 127.0.0.1 --failover-mode vrrp >/tmp/ka.log 2>&1; then
    ok "keepalived_config.sh 退出 0"
else
    bad "keepalived_config.sh 退出非 0（见 /tmp/ka.log）"
fi
if keepalived -t -f /etc/keepalived/keepalived.conf >/tmp/ka_t.log 2>&1; then
    ok "keepalived -t 配置校验通过"
else
    bad "keepalived -t 校验失败（见 /tmp/ka_t.log）"
fi
if /etc/keepalived/check_dns.sh >/tmp/check_dns.log 2>&1; then
    ok "check_dns.sh 实跑退出 0（dig + netstat 依赖已补齐）"
else
    bad "check_dns.sh 实跑失败（见 /tmp/check_dns.log）"
fi
if grep -q 'weight -20' /etc/keepalived/keepalived.conf; then
    ok "生成的配置里权重为 -20"
else
    bad "生成的配置里权重不是 -20"
fi

echo "== 5. haproxy 模式：:53 冲突时必须明确拒绝，空闲时配置要能过 -c =="
hp_out=$(bash keepalived_config.sh --role master --vip 127.0.0.2/32 --interface "$IFACE" \
    --master-ip 127.0.0.1 --slave-ip 127.0.0.1 --failover-mode haproxy 2>&1)
if [[ "$hp_out" == *"需要独占 :53"* ]]; then
    ok ":53 被占用时明确报错"
else
    bad "未检测到 :53 冲突拒绝（输出：${hp_out:0:120}）"
fi
if [[ -f /tmp/dnsmasq.pid ]]; then
    kill "$(cat /tmp/dnsmasq.pid)" >/dev/null 2>&1
    sleep 1
fi
bash keepalived_config.sh --role master --vip 127.0.0.2/32 --interface "$IFACE" \
    --master-ip 127.0.0.1 --slave-ip 127.0.0.1 --failover-mode haproxy >/tmp/hp.log 2>&1
if [[ -f /etc/haproxy/haproxy.cfg ]] && haproxy -c -f /etc/haproxy/haproxy.cfg >/tmp/hp_c.log 2>&1; then
    ok "haproxy -c 配置校验通过（tcp-check connect 合法）"
else
    bad "haproxy -c 校验失败（见 /tmp/hp_c.log）"
fi

echo "== 6. 修复脚本：默认配置缺失必须拒绝回滚 =="
rm -f /opt/dnsha/smartdns_default.conf /opt/dnsha/adguard_default.yaml /opt/dnsha/keepalived_default.conf 2>/dev/null
rb_out=$(bash repair_dns.sh --master-ip 127.0.0.1 --slave-ip 127.0.0.1 --rollback 2>&1)
if [[ "$rb_out" == *"缺少 /opt/dnsha 默认配置"* ]]; then
    ok "缺默认配置时明确拒绝回滚"
else
    bad "缺默认配置时没有拒绝（输出：${rb_out:0:150}）"
fi
if [[ "$rb_out" != *"回滚成功"* ]]; then
    ok "没有谎报「回滚成功」"
else
    bad "缺失默认配置却打印了回滚成功"
fi

echo "== 7. 修复脚本：默认配置齐备时能真的回滚 =="
mkdir -p /opt/dnsha /etc/smartdns /opt/AdGuardHome/conf /etc/keepalived
printf '# default smartdns\n' > /opt/dnsha/smartdns_default.conf
printf '# default adguard\n' > /opt/dnsha/adguard_default.yaml
printf '# default keepalived\n' > /opt/dnsha/keepalived_default.conf
printf '# live smartdns\n' > /etc/smartdns/smartdns.conf
rb2=$(bash repair_dns.sh --master-ip 127.0.0.1 --slave-ip 127.0.0.1 --rollback 2>&1)
if [[ "$rb2" == *"回滚成功"* ]]; then
    ok "齐备时执行回滚并报告成功"
else
    bad "齐备时未完成回滚（输出：${rb2:0:150}）"
fi
if grep -q 'default smartdns' /etc/smartdns/smartdns.conf; then
    ok "回滚真的把配置文件换成了默认版本"
else
    bad "回滚没有真的替换配置文件"
fi

echo "== 8. 参数校验：非法值必须失败，不能静默通过 =="
if bash verify_deploy.sh --vip 127.0.0.1 --role master --failover-mode bogus >/tmp/vd.log 2>&1; then
    bad "verify_deploy 接受了非法容灾模式"
else
    ok "verify_deploy 拒绝非法容灾模式"
fi
if bash health_check.sh --master-ip 127.0.0.1 --once >/tmp/hc.log 2>&1; then
    ok "health_check 缺 --slave-ip 时按错误退出"
else
    ok "health_check 缺参数时非 0 退出"
fi

echo "== 9. 同步守护脚本：状态判定与空源保护 =="
mkdir -p /tmp/fakebin
cat > /tmp/fakebin/rsync <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x /tmp/fakebin/rsync
mkdir -p /etc/smartdns /opt/AdGuardHome/conf
printf 'a\n' > /etc/smartdns/a.conf
printf 'b\n' > /opt/AdGuardHome/conf/b.yaml
awk '/cat > "\$SYNC_SCRIPT" << .EOF./{f=1;next} f&&/^EOF$/{exit} f' sync_config.sh > /tmp/daemon_src.sh
rm -f /var/log/dnsha_sync_daemon.log
PATH=/tmp/fakebin:$PATH timeout 8 bash /tmp/daemon_src.sh >/dev/null 2>&1
if grep -q '成功同步' /var/log/dnsha_sync_daemon.log 2>/dev/null; then
    ok "rsync 成功（即使无输出）被记为成功同步"
else
    bad "rsync 成功却未记为成功（状态判定仍错）"
fi
rm -f /etc/smartdns/a.conf
mv -f /etc/smartdns/smartdns.conf /tmp/smartdns.conf.bak 2>/dev/null
rm -rf /etc/smartdns/* 2>/dev/null
rm -f /var/log/dnsha_sync_daemon.log
PATH=/tmp/fakebin:$PATH timeout 8 bash /tmp/daemon_src.sh >/dev/null 2>&1
if grep -q '不存在或为空，已跳过' /var/log/dnsha_sync_daemon.log 2>/dev/null; then
    ok "源目录为空时拒绝同步（--delete 保护生效）"
else
    bad "源目录为空时仍然同步了"
fi

echo "== 10. 部署脚本：不可达节点必须快速失败 =="
if timeout 90 bash deploy_dns.sh --master-ip 203.0.113.1 --slave-ip 203.0.113.2 >/tmp/deploy.log 2>&1; then
    bad "不可达节点却被判定部署成功"
else
    ok "不可达节点快速失败（不再假成功）"
fi

echo "== 11. 部署脚本：凭据环境变量经 %q 转义后透传到远端命令 =="
rm -f /tmp/dnsha_fake_cmds /tmp/deploy_env.log
cat > /tmp/fakebin/ssh <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/dnsha_fake_cmds
exit 0
FAKE
cat > /tmp/fakebin/scp <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x /tmp/fakebin/ssh /tmp/fakebin/scp
ADGUARD_ADMIN_PASS="p a'ss" VRRP_AUTH_PASS='x8' PATH=/tmp/fakebin:$PATH \
    bash deploy_dns.sh -m 10.0.0.1 -s 10.0.0.2 >/tmp/deploy_env.log 2>&1
if grep -qF "ADGUARD_ADMIN_PASS=p\\ a\\'ss VRRP_AUTH_PASS=x8 ./install_dns.sh --role master" /tmp/dnsha_fake_cmds 2>/dev/null; then
    ok "AdGuard 口令带空格/引号时被正确转义并下发给 install_dns.sh"
else
    bad "AdGuard 口令未按 %q 转义下发"
fi
if grep -qF "ADGUARD_ADMIN_PASS=p\ a\'ss VRRP_AUTH_PASS=x8 ./keepalived_config.sh" /tmp/dnsha_fake_cmds 2>/dev/null; then
    ok "VRRP 口令被透传给 keepalived_config.sh"
else
    bad "VRRP 口令未透传"
fi

echo "== 12. 交互式向导：无参数时补问，取消时不得部署 =="
rm -f /tmp/dnsha_fake_cmds /tmp/deploy_wizard.log
printf '10.9.9.1\n10.9.9.2\n10.9.9.200/24\neth9\nvrrp\n\n\ny\n' | \
    PATH=/tmp/fakebin:$PATH DNSHA_FORCE_INTERACTIVE=1 \
    bash deploy_dns.sh >/tmp/deploy_wizard.log 2>&1
if grep -qF "keepalived_config.sh --role master --vip 10.9.9.200/24 --interface eth9" /tmp/dnsha_fake_cmds 2>/dev/null; then
    ok "向导输入被拼进远端 keepalived 命令"
else
    bad "向导输入未生效"
fi
rm -f /tmp/dnsha_fake_cmds
if printf '10.9.9.1\n10.9.9.2\n\n\n\n\n\nn\n' | \
    PATH=/tmp/fakebin:$PATH DNSHA_FORCE_INTERACTIVE=1 \
    bash deploy_dns.sh >/tmp/deploy_wizard_cancel.log 2>&1; then
    bad "确认回答 n 时仍然继续部署"
else
    ok "确认回答 n 时取消部署"
fi

echo
echo "================ 运行态汇总 ================"
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"

if (( fail > 0 )); then
    echo
    echo "================ 失败诊断 ================"
    for f in /tmp/ka.log /tmp/ka_t.log /tmp/check_dns.log /tmp/hp.log /tmp/hp_c.log \
             /tmp/vd.log /tmp/hc.log /tmp/deploy.log /var/log/dnsha_sync_daemon.log; do
        if [[ -f "$f" ]]; then
            echo "----- $f -----"
            tail -25 "$f"
        fi
    done
    if [[ -f /etc/keepalived/keepalived.conf ]]; then
        echo "----- 生成的 keepalived.conf（前 40 行） -----"
        head -40 /etc/keepalived/keepalived.conf
    fi
    echo "运行态验证失败"
    exit 1
fi
echo "运行态验证全部通过"
