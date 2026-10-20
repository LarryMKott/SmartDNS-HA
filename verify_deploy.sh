#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# 部署验证脚本 - 验证单个节点部署结果
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_verify.log"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

# 日志函数
log() {
    local level=$1
    local msg=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

echo_success() {
    log "${GREEN}SUCCESS${NC}" "$1"
}

echo_error() {
    log "${RED}ERROR${NC}" "$1"
    return 1
}

echo_warning() {
    log "${YELLOW}WARNING${NC}" "$1"
    return 1
}

echo_info() {
    log "${BLUE}INFO${NC}" "$1"
}

# 显示帮助信息
show_help() {
    cat << EOF
DNSHA 部署验证脚本

Usage: $0 [OPTIONS]

Options:
  --vip, -v <IP>            虚拟IP地址（必填，如：192.168.1.200）
  --role, -r <ROLE>         节点角色：master 或 slave（必填）
  --failover-mode, -f <MODE> 容灾模式：vrrp（默认）、haproxy、consul
  --help, -h               显示帮助信息

Examples:
  # 验证主节点部署
  $0 --vip 192.168.1.200 --role master
  
  # 验证备节点部署
  $0 --vip 192.168.1.200 --role slave
EOF
    exit 0
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --vip|-v)
                VIP="$2"
                shift 2
                ;;
            --role|-r)
                ROLE="$2"
                shift 2
                ;;
            --failover-mode|-f)
                FAILOVER_MODE="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                ;;
            *)
                echo_error "未知参数：$1"
                ;;
        esac
    done
}

# 验证参数
validate_params() {
    [[ -z "$VIP" ]] && echo_error "必须指定虚拟IP（--vip）"
    [[ -z "$ROLE" ]] && echo_error "必须指定节点角色（--role）"
    [[ "$ROLE" != "master" && "$ROLE" != "slave" ]] && echo_error "节点角色必须是 master 或 slave"
    
    # 设置默认值
    FAILOVER_MODE=${FAILOVER_MODE:-"vrrp"}
    
    # 模式必须是已知取值，否则下面的检查会全部「跳过」并通过
    case "$FAILOVER_MODE" in
        vrrp|haproxy|consul) ;;
        *) echo_error "容灾模式必须是 vrrp、haproxy 或 consul（当前：$FAILOVER_MODE）"; exit 1 ;;
    esac
    
    echo_info "验证参数："
    echo_info "  VIP: $VIP"
    echo_info "  角色: $ROLE"
    echo_info "  容灾模式: $FAILOVER_MODE"
}

# 检查SmartDNS服务
test_smartdns() {
    echo -n "✓ 检查SmartDNS服务: "
    
    # 检查进程
    if pgrep -f smartdns >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${NC}"
        return 0
    else
        echo -e "${RED}未运行${NC}"
        return 1
    fi
}

# 检查AdGuard Home服务
test_adguard() {
    echo -n "✓ 检查AdGuard Home服务: "
    
    # 检查进程
    if pgrep -f AdGuardHome >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${NC}"
        return 0
    else
        echo -e "${RED}未运行${NC}"
        return 1
    fi
}

# 检查VIP绑定
test_vip() {
    echo -n "✓ 检查VIP绑定: "
    
    local vip_found
    vip_found=$(ip -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$VIP" && echo "yes" || echo "no")
    
    if [[ "$ROLE" == "master" ]]; then
        # 主节点应绑定VIP
        if [[ "$vip_found" == "yes" ]]; then
            echo -e "${GREEN}已绑定${NC}"
            return 0
        else
            echo -e "${RED}未绑定${NC}"
            return 1
        fi
    else
        # 备节点不应绑定VIP
        if [[ "$vip_found" == "no" ]]; then
            echo -e "${GREEN}未绑定${NC}"
            return 0
        else
            echo -e "${YELLOW}已绑定（备节点不应该绑定VIP）${NC}"
            return 1
        fi
    fi
}

# 检查Keepalived服务
test_keepalived() {
    echo -n "✓ 检查Keepalived服务: "
    
    # 仅在VRRP模式下检查
    if [[ "$FAILOVER_MODE" == "vrrp" ]]; then
        if pgrep -f keepalived >/dev/null 2>&1; then
            echo -e "${GREEN}运行中${NC}"
            return 0
        else
            echo -e "${RED}未运行${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}跳过（非VRRP模式）${NC}"
        return 0
    fi
}

# 检查Haproxy服务
test_haproxy() {
    echo -n "✓ 检查Haproxy服务: "
    
    # 仅在Haproxy模式下检查
    if [[ "$FAILOVER_MODE" == "haproxy" ]]; then
        if pgrep -f haproxy >/dev/null 2>&1; then
            echo -e "${GREEN}运行中${NC}"
            return 0
        else
            echo -e "${RED}未运行${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}跳过（非Haproxy模式）${NC}"
        return 0
    fi
}

# 检查Consul服务
test_consul() {
    echo -n "✓ 检查Consul服务: "
    
    # 仅在Consul模式下检查
    if [[ "$FAILOVER_MODE" == "consul" ]]; then
        if pgrep -f consul >/dev/null 2>&1; then
            echo -e "${GREEN}运行中${NC}"
            return 0
        else
            echo -e "${YELLOW}未运行（可选服务）${NC}"
            return 0
        fi
    else
        echo -e "${YELLOW}跳过（非Consul模式）${NC}"
        return 0
    fi
}

# 检查配置同步服务
test_sync_service() {
    echo -n "✓ 检查配置同步服务: "
    
    if systemctl is-active dns_config_sync >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${NC}"
        return 0
    else
        echo -e "${YELLOW}未运行${NC}"
        return 1
    fi
}

# 检查DNS解析功能
test_dns_resolve() {
    echo -n "✓ 检查DNS解析功能: "
    
    # 测试本地DNS解析
    local resolve_result
    resolve_result=$(dig @127.0.0.1 www.baidu.com +short +timeout=2 2>/dev/null | head -1)
    if [[ -n "$resolve_result" ]]; then
        echo -e "${GREEN}正常${NC}"
        return 0
    else
        echo -e "${RED}失败${NC}"
        return 1
    fi
}

# 检查端口监听
test_ports() {
    echo -n "✓ 检查端口监听: "
    
    # 检查必要端口
    local ports_ok=1
    
    # DNS端口（53）
    if ! netstat -tuln | grep -q ":53\b"; then
        ports_ok=0
    fi
    
    # AdGuard Home管理端口（8080）
    if ! netstat -tuln | grep -q ":8080\b"; then
        ports_ok=0
    fi
    
    if [[ $ports_ok -eq 1 ]]; then
        echo -e "${GREEN}正常${NC}"
        return 0
    else
        echo -e "${RED}异常${NC}"
        return 1
    fi
}

# 主验证流程
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 部署验证报告${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    echo -e "\n${YELLOW}开始验证$ROLE节点部署结果...${NC}"
    
    local error_count=0
    
    # 执行各项测试
    test_smartdns || ((error_count++))
    test_adguard || ((error_count++))
    test_vip || ((error_count++))
    test_keepalived || ((error_count++))
    test_haproxy || ((error_count++))
    test_consul || ((error_count++))
    test_sync_service || ((error_count++))
    test_dns_resolve || ((error_count++))
    test_ports || ((error_count++))
    
    echo -e "\n${BLUE}=====================================${NC}"
    echo -e "${YELLOW}验证结果${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    if [[ $error_count -eq 0 ]]; then
        echo -e "${GREEN}🎉 所有测试通过！部署成功！${NC}"
        echo_success "$ROLE节点部署验证通过"
        exit 0
    elif [[ $error_count -lt 3 ]]; then
        echo -e "${YELLOW}⚠ 部分测试失败（$error_count个问题），建议检查${NC}"
        echo_warning "$ROLE节点部署验证警告"
        exit 1
    else
        echo -e "${RED}✗ 部署失败！存在$error_count个严重问题${NC}"
        echo_error "$ROLE节点部署验证失败"
        exit 1
    fi
}

# 脚本入口
main "$@"
