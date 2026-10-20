#!/usr/bin/env bash
# SmartDNS-HA 自检：把走查修复过的每一个"假成功/假检查"变成可执行断言
# 用法：bash tests/selftest.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
chk() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "== 1. 语法（bash -n）=="
for f in *.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

echo "== 2. 退出码不被 local 遮蔽（#2）=="
if grep -n -A2 'local [A-Za-z_]*=\$(' *.sh 2>/dev/null | grep -q '\[\[ \$?'; then
    bad "仍存在 local x=\$(...) 紧跟 \$? 的写法"
else
    ok "无 local 遮蔽退出码"
fi

count=$(grep -c 'rc=\$?' deploy_dns.sh)
if [[ "$count" == "5" ]]; then ok "deploy_dns 显式 rc 捕获 5 处"; else bad "deploy_dns rc 捕获为 $count（期望 5）"; fi

echo "== 3. 配置同步用 rsync 自身退出码（#5）=="
if grep -q 'grep -v "sending' sync_config.sh; then
    bad "sync_config 仍有 grep 管道覆盖 rsync 状态"
else
    ok "sync_config 无 grep 管道"
fi
if grep -q 'if rsync -avz --delete' sync_config.sh; then ok "rsync 出现在 if 条件中"; else bad "rsync 未用于条件判定"; fi
if grep -q '不存在或为空，已跳过' sync_config.sh; then ok "--delete 源目录保护存在"; else bad "缺少 --delete 源目录保护"; fi

echo "== 4. 生成的同步守护脚本可解析 =="
awk '/cat > "\$SYNC_SCRIPT" << .EOF./{f=1;next} f&&/^EOF$/{exit} f' sync_config.sh > /tmp/_dnsha_daemon.sh 2>/dev/null
if [[ -s /tmp/_dnsha_daemon.sh ]] && bash -n /tmp/_dnsha_daemon.sh 2>/dev/null; then
    ok "生成脚本语法有效"
else
    bad "生成脚本语法无效"
fi

echo "== 5. keepalived 权重必须大于主备优先级差（#7）=="
prios=$(grep -o 'PRIORITY:-[0-9]*' keepalived_config.sh | grep -o '[0-9]*')
master=$(printf '%s\n' "$prios" | head -1)
backup=$(printf '%s\n' "$prios" | tail -1)
weight=$(grep -o 'weight -[0-9]*' keepalived_config.sh | head -1 | grep -o '[0-9]*')
if [[ -n "$master" && -n "$backup" && -n "$weight" ]]; then
    gap=$((master - backup))
    if (( weight > gap )); then
        ok "权重 $weight > 优先级差 $gap（故障后 $((master - weight)) < $backup）"
    else
        bad "权重 $weight <= 优先级差 $gap，故障后平局"
    fi
else
    bad "未能解析优先级/权重"
fi

echo "== 6. DNS 链路端口自洽（#8）=="
adguard_up=$(grep -o '127\.0\.0\.1:[0-9]*' install_dns.sh | head -1 | cut -d: -f2)
smartdns_bind=$(grep -o 'bind \[::\]:[0-9]*' install_dns.sh | head -1 | grep -o '[0-9]*$')
if [[ -n "$adguard_up" && "$adguard_up" == "$smartdns_bind" ]]; then
    ok "AdGuard 上游 $adguard_up == smartdns 监听 $smartdns_bind"
else
    bad "AdGuard 上游 $adguard_up != smartdns 监听 $smartdns_bind"
fi
if grep -q 'tcp-check send QUERY' keepalived_config.sh; then
    bad "haproxy 仍在发送非 DNS 线格式报文"
else
    ok "haproxy 无非法 tcp-check send"
fi
if grep -q 'tcp-check connect' keepalived_config.sh; then ok "haproxy 使用 TCP 连接检查"; else bad "haproxy 缺少 TCP 连接检查"; fi
if grep -q 'haproxy 模式需要独占 :53' keepalived_config.sh; then ok "haproxy 端口冲突显式报错"; else bad "缺少 haproxy 端口冲突检查"; fi

echo "== 7. install.sh 不覆写系统网络配置（#9）=="
if grep -q 'cat > "\$netplan_file"' install.sh; then
    bad "仍存在整文件覆写 netplan"
else
    ok "netplan 不再被整文件覆写"
fi
dropins=$(grep -c '99-dnsha-' install.sh)
if (( dropins >= 3 )); then ok "drop-in 文件 $dropins 处"; else bad "drop-in 只有 $dropins 处（期望 >=3）"; fi
if grep -q 'read -rsp' install.sh; then ok "Token 输入不回显"; else bad "Token 仍明文回显"; fi
if grep -q 'chmod 700 /opt/dnsha/cloudflare_ddns.sh' install.sh; then ok "DDNS 脚本权限 700"; else bad "DDNS 脚本权限未收紧"; fi
if grep -qE '^[[:space:]]*gateway4:' install.sh; then bad "仍写入已弃用的 gateway4"; else ok "无 gateway4 写入"; fi

echo "== 8. 假阳性检查已修（#4）=="
if awk '/^echo_error\(\)/,/^}/' health_check.sh | grep -q 'exit 1'; then
    ok "health_check 参数错误会退出"
else
    bad "health_check echo_error 不退出"
fi
if grep -q -A2 'local total_errors=' health_check.sh; then ok "total_errors 有定义"; else bad "total_errors 未定义"; fi
if grep -q "grep -qx" health_check.sh; then ok "VIP 精确匹配"; else bad "VIP 仍用正则模糊匹配"; fi
if grep -q 'vrrp|haproxy|consul' verify_deploy.sh; then ok "FAILOVER_MODE 有取值校验"; else bad "FAILOVER_MODE 未校验"; fi
if grep -q 'iptables -C INPUT' install_dns.sh; then ok "iptables 规则幂等"; else bad "iptables 仍重复追加"; fi

echo "== 9. 安全底线 =="
if grep -n 'admin123456' *.sh 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then
    bad "仍存在硬编码弱口令 admin123456"
else
    ok "无硬编码弱口令（注释提及不计）"
fi
if grep -q 'stats auth admin:admin123456' keepalived_config.sh; then bad "haproxy 统计页仍弱口令"; else ok "haproxy 统计页无弱口令"; fi
if grep -q 'bind \*:8081' keepalived_config.sh; then bad "haproxy 统计页仍监听全接口"; else ok "haproxy 统计页只监听回环"; fi

echo "== 10. root 权限检查 =="
for f in deploy_dns.sh install_dns.sh keepalived_config.sh repair_dns.sh sync_config.sh; do
    if grep -q '需要 root 权限运行' "$f"; then ok "$f 有 root 检查"; else bad "$f 缺 root 检查"; fi
done

echo
echo "================ 汇总 ================"
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"
if (( fail > 0 )); then
    echo "自检失败"
    exit 1
fi
echo "自检全部通过"
