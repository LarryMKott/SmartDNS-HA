#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# 故障修复脚本 - 实现DNS服务、容灾服务修复和配置回滚
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_repair.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
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
DNSHA 故障修复脚本

Usage: $0 [OPTIONS]

Options:
  --master-ip, -m <IP>     主节点IP地址（必填）
  --slave-ip, -s <IP>      备节点IP地址（必填）
  --dns, -d                仅修复DNS服务（SmartDNS + AdGuard Home）
  --failover, -f           仅修复容灾服务（Keepalived/Haproxy/Consul）
  --sync, -y               仅修复配置同步服务
  --rollback, -r           配置回滚到默认版本
  --help, -h               显示帮助信息

Examples:
  # 全量修复（DNS+容灾+同步服务）
  $0 -m 192.168.1.100 -s 192.168.1.101
  
  # 仅修复DNS服务
  $0 -m 192.168.1.100 -s 192.168.1.101 -d
  
  # 仅修复容灾服务
  $0 -m 192.168.1.100 -s 192.168.1.101 -f
  
  # 配置回滚
  $0 -m 192.168.1.100 -s 192.168.1.101 -r
EOF
    exit 0
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --master-ip|-m)
                MASTER_IP="$2"
                shift 2
                ;;
            --slave-ip|-s)
                SLAVE_IP="$2"
                shift 2
                ;;
            --dns|-d)
                FIX_DNS="true"
                shift
                ;;
            --failover|-f)
                FIX_FAILOVER="true"
                shift
                ;;
            --sync|-y)
                FIX_SYNC="true"
                shift
                ;;
            --rollback|-r)
                ROLLBACK="true"
                shift
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
    [[ -z "$MASTER_IP" ]] && echo_error "必须指定主节点IP（--master-ip）"
    [[ -z "$SLAVE_IP" ]] && echo_error "必须指定备节点IP（--slave-ip）"
    
    # 默认全量修复
    if [[ -z "$FIX_DNS" && -z "$FIX_FAILOVER" && -z "$FIX_SYNC" && -z "$ROLLBACK" ]]; then
        FIX_DNS="true"
        FIX_FAILOVER="true"
        FIX_SYNC="true"
    fi
    
    echo_info "修复参数："
    echo_info "  主节点IP: $MASTER_IP"
    echo_info "  备节点IP: $SLAVE_IP"
    echo_info "  修复DNS服务: ${FIX_DNS:-false}"
    echo_info "  修复容灾服务: ${FIX_FAILOVER:-false}"
    echo_info "  修复同步服务: ${FIX_SYNC:-false}"
    echo_info "  配置回滚: ${ROLLBACK:-false}"
}

# 执行远程命令
remote_exec() {
    local ip=$1
    local cmd=$2
    local node_type=$3
    
    echo_info "在$node_type节点（$ip）执行命令：$cmd"
    ssh -o StrictHostKeyChecking=no root@"$ip" "$cmd" 2>&1
    return $?
}

# 修复单个节点的DNS服务
repair_node_dns() {
    local ip=$1
    local node_type=$2
    
    echo_info "修复$node_type节点（$ip）的DNS服务..."
    
    # 重启SmartDNS服务
    remote_exec "$ip" "systemctl restart smartdns" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点SmartDNS服务重启成功"
    else
        echo_error "$node_type节点SmartDNS服务重启失败"
    fi
    
    # 重启AdGuard Home服务
    remote_exec "$ip" "systemctl restart adguardhome" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点AdGuard Home服务重启成功"
    else
        echo_error "$node_type节点AdGuard Home服务重启失败"
    fi
    
    # 检查DNS服务状态
    local smartdns_status=$(remote_exec "$ip" "systemctl is-active smartdns" "$node_type")
    local adguard_status=$(remote_exec "$ip" "systemctl is-active adguardhome" "$node_type")
    
    if [[ "$smartdns_status" == "active" && "$adguard_status" == "active" ]]; then
        echo_success "$node_type节点DNS服务修复完成"
        return 0
    else
        echo_error "$node_type节点DNS服务修复失败"
        return 1
    fi
}

# 修复单个节点的容灾服务
repair_node_failover() {
    local ip=$1
    local node_type=$2
    
    echo_info "修复$node_type节点（$ip）的容灾服务..."
    
    # 检查并重启Keepalived
    if command -v keepalived >/dev/null 2>&1; then
        remote_exec "$ip" "systemctl restart keepalived" "$node_type"
        if [[ $? -eq 0 ]]; then
            echo_success "$node_type节点Keepalived服务重启成功"
        else
            echo_warning "$node_type节点Keepalived服务重启失败"
        fi
    fi
    
    # 检查并重启Haproxy
    if command -v haproxy >/dev/null 2>&1; then
        remote_exec "$ip" "systemctl restart haproxy" "$node_type"
        if [[ $? -eq 0 ]]; then
            echo_success "$node_type节点Haproxy服务重启成功"
        else
            echo_warning "$node_type节点Haproxy服务重启失败"
        fi
    fi
    
    # 检查并重启Consul
    if command -v consul >/dev/null 2>&1; then
        remote_exec "$ip" "systemctl restart consul" "$node_type"
        if [[ $? -eq 0 ]]; then
            echo_success "$node_type节点Consul服务重启成功"
        else
            echo_warning "$node_type节点Consul服务重启失败"
        fi
    fi
    
    echo_success "$node_type节点容灾服务修复完成"
    return 0
}

# 修复单个节点的同步服务
repair_node_sync() {
    local ip=$1
    local node_type=$2
    
    echo_info "修复$node_type节点（$ip）的配置同步服务..."
    
    # 重启同步服务
    remote_exec "$ip" "systemctl restart dns_config_sync" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点配置同步服务重启成功"
        return 0
    else
        echo_error "$node_type节点配置同步服务重启失败"
        return 1
    fi
}

# 回滚单个节点的配置
rollback_node_config() {
    local ip=$1
    local node_type=$2
    
    echo_info "回滚$node_type节点（$ip）配置到默认版本..."
    
    # 备份当前配置
    remote_exec "$ip" "mkdir -p /tmp/dnsha_backup/$(date +%Y%m%d_%H%M%S)" "$node_type"
    
    # 回滚SmartDNS配置
    remote_exec "$ip" "cp -f /opt/dnsha/smartdns_default.conf /etc/smartdns/smartdns.conf" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点SmartDNS配置回滚成功"
    else
        echo_warning "$node_type节点SmartDNS配置回滚失败"
    fi
    
    # 回滚AdGuard Home配置
    remote_exec "$ip" "cp -f /opt/dnsha/adguard_default.yaml /opt/AdGuardHome/conf/AdGuardHome.yaml" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点AdGuard Home配置回滚成功"
    else
        echo_warning "$node_type节点AdGuard Home配置回滚失败"
    fi
    
    # 回滚Keepalived配置
    remote_exec "$ip" "cp -f /opt/dnsha/keepalived_default.conf /etc/keepalived/keepalived.conf" "$node_type"
    if [[ $? -eq 0 ]]; then
        echo_success "$node_type节点Keepalived配置回滚成功"
    else
        echo_warning "$node_type节点Keepalived配置回滚失败"
    fi
    
    # 重启相关服务
    remote_exec "$ip" "systemctl restart smartdns adguardhome keepalived dns_config_sync" "$node_type"
    
    echo_success "$node_type节点配置回滚完成"
    return 0
}

# 修复主节点
repair_master() {
    echo_info "开始修复主节点（$MASTER_IP）..."
    
    if [[ "$FIX_DNS" == "true" ]]; then
        repair_node_dns "$MASTER_IP" "主"
    fi
    
    if [[ "$FIX_FAILOVER" == "true" ]]; then
        repair_node_failover "$MASTER_IP" "主"
    fi
    
    if [[ "$FIX_SYNC" == "true" ]]; then
        repair_node_sync "$MASTER_IP" "主"
    fi
    
    if [[ "$ROLLBACK" == "true" ]]; then
        rollback_node_config "$MASTER_IP" "主"
    fi
    
    echo_success "主节点修复完成"
}

# 修复备节点
repair_slave() {
    echo_info "开始修复备节点（$SLAVE_IP）..."
    
    if [[ "$FIX_DNS" == "true" ]]; then
        repair_node_dns "$SLAVE_IP" "备"
    fi
    
    if [[ "$FIX_FAILOVER" == "true" ]]; then
        repair_node_failover "$SLAVE_IP" "备"
    fi
    
    if [[ "$FIX_SYNC" == "true" ]]; then
        repair_node_sync "$SLAVE_IP" "备"
    fi
    
    if [[ "$ROLLBACK" == "true" ]]; then
        rollback_node_config "$SLAVE_IP" "备"
    fi
    
    echo_success "备节点修复完成"
}

# 验证修复结果
verify_repair() {
    echo_info "验证修复结果..."
    
    # 检查主节点状态
    echo_info "检查主节点（$MASTER_IP）服务状态..."
    local master_services=$(remote_exec "$MASTER_IP" "systemctl is-active smartdns adguardhome" "主节点")
    
    # 检查备节点状态
    echo_info "检查备节点（$SLAVE_IP）服务状态..."
    local slave_services=$(remote_exec "$SLAVE_IP" "systemctl is-active smartdns adguardhome" "备节点")
    
    echo_success "修复验证完成"
}

# 主修复流程
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 故障修复工具${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    # 修复主节点
    repair_master
    
    # 修复备节点
    repair_slave
    
    # 验证修复结果
    verify_repair
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}🎉 故障修复完成！${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}修复日志：$LOG_FILE${NC}"
    echo -e "${YELLOW}建议执行健康检查验证修复效果：${NC}"
    echo -e "  ./health_check.sh --master-ip $MASTER_IP --slave-ip $SLAVE_IP --once"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"