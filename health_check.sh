#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# 健康检查脚本 - 实时监控主备节点状态
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_health.log"
DEFAULT_INTERVAL=5

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
}

echo_warning() {
    log "${YELLOW}WARNING${NC}" "$1"
}

echo_info() {
    log "${BLUE}INFO${NC}" "$1"
}

# 显示帮助信息
show_help() {
    cat << EOF
DNSHA 健康检查脚本

Usage: $0 [OPTIONS]

Options:
  --master-ip, -m <IP>     主节点IP地址（必填）
  --slave-ip, -s <IP>      备节点IP地址（必填）
  --vip, -v <IP>           虚拟IP地址（可选，默认192.168.1.200）
  --interval, -i <SEC>     检查间隔（秒，默认5秒）
  --once, -o               仅检查一次（默认循环检查）
  --help, -h               显示帮助信息

Examples:
  # 循环监控（每5秒刷新）
  $0 -m 192.168.1.100 -s 192.168.1.101 -i 5
  
  # 仅检查一次
  $0 -m 192.168.1.100 -s 192.168.1.101 -o
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
            --vip|-v)
                VIP="$2"
                shift 2
                ;;
            --interval|-i)
                INTERVAL="$2"
                shift 2
                ;;
            --once|-o)
                ONCE="true"
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
    
    # 设置默认值
    VIP=${VIP:-"192.168.1.200"}
    INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}
    ONCE=${ONCE:-"false"}
    
    # 验证间隔参数
    [[ "$INTERVAL" =~ ^[0-9]+$ ]] || echo_error "检查间隔必须是正整数"
    [[ "$INTERVAL" -lt 1 ]] && echo_error "检查间隔不能小于1秒"
}

# 执行远程命令
remote_exec() {
    local ip=$1
    local cmd=$2
    local node_type=$3
    
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "$cmd" 2>&1
}

# 检查节点SSH连接
check_ssh() {
    local ip=$1
    local node_type=$2
    
    echo -n "  SSH连接: "
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "echo 'ssh_ok'" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ 正常${NC}"
        return 0
    else
        echo -e "${RED}✗ 失败${NC}"
        return 1
    fi
}

# 检查SmartDNS服务状态
check_smartdns() {
    local ip=$1
    local node_type=$2
    
    echo -n "  SmartDNS: "
    local status=$(remote_exec "$ip" "systemctl is-active smartdns" "$node_type")
    if [[ "$status" == "active" ]]; then
        echo -e "${GREEN}✓ 运行中${NC}"
        return 0
    else
        echo -e "${RED}✗ 未运行${NC}"
        return 1
    fi
}

# 检查AdGuard Home服务状态
check_adguard() {
    local ip=$1
    local node_type=$2
    
    echo -n "  AdGuardHome: "
    local status=$(remote_exec "$ip" "systemctl is-active adguardhome" "$node_type")
    if [[ "$status" == "active" ]]; then
        echo -e "${GREEN}✓ 运行中${NC}"
        return 0
    else
        echo -e "${RED}✗ 未运行${NC}"
        return 1
    fi
}

# 检查Keepalived服务状态
check_keepalived() {
    local ip=$1
    local node_type=$2
    
    echo -n "  Keepalived: "
    local status=$(remote_exec "$ip" "systemctl is-active keepalived 2>/dev/null || echo 'inactive'" "$node_type")
    if [[ "$status" == "active" ]]; then
        echo -e "${GREEN}✓ 运行中${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ 未运行${NC}"
        return 1
    fi
}

# 检查VIP绑定状态
check_vip() {
    local ip=$1
    local node_type=$2
    
    echo -n "  VIP绑定: "
    local vip_status=$(remote_exec "$ip" "ip addr | grep -q '$VIP' && echo 'bound' || echo 'unbound'" "$node_type")
    if [[ "$vip_status" == "bound" ]]; then
        echo -e "${GREEN}✓ 已绑定${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ 未绑定${NC}"
        return 1
    fi
}

# 检查DNS解析功能
check_dns_resolve() {
    local ip=$1
    local node_type=$2
    
    echo -n "  DNS解析: "
    local resolve_result=$(remote_exec "$ip" "dig @127.0.0.1 www.baidu.com +short +timeout=2 2>/dev/null | head -1" "$node_type")
    if [[ -n "$resolve_result" ]]; then
        echo -e "${GREEN}✓ 正常${NC}"
        return 0
    else
        echo -e "${RED}✗ 失败${NC}"
        return 1
    fi
}

# 检查配置同步服务
check_sync_service() {
    local ip=$1
    local node_type=$2
    
    echo -n "  同步服务: "
    local sync_status=$(remote_exec "$ip" "systemctl is-active dns_config_sync 2>/dev/null || echo 'inactive'" "$node_type")
    if [[ "$sync_status" == "active" ]]; then
        echo -e "${GREEN}✓ 运行中${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ 未运行${NC}"
        return 1
    fi
}

# 检查节点磁盘空间
check_disk_space() {
    local ip=$1
    local node_type=$2
    
    echo -n "  磁盘空间: "
    local disk_usage=$(remote_exec "$ip" "df -h / | tail -1 | awk '{print $5}' | sed 's/%//'" "$node_type")
    if [[ "$disk_usage" -lt 80 ]]; then
        echo -e "${GREEN}✓ $disk_usage%${NC}"
        return 0
    elif [[ "$disk_usage" -lt 90 ]]; then
        echo -e "${YELLOW}⚠ $disk_usage%${NC}"
        return 1
    else
        echo -e "${RED}✗ $disk_usage%${NC}"
        return 1
    fi
}

# 检查单个节点状态
check_node() {
    local ip=$1
    local node_type=$2
    local role=$3
    
    echo -e "\n${BLUE}[$node_type节点: $ip]${NC}"
    echo -e "${BLUE}-------------------------------------${NC}"
    
    local error_count=0
    
    # 检查各项状态
    check_ssh "$ip" "$node_type" || ((error_count++))
    check_smartdns "$ip" "$node_type" || ((error_count++))
    check_adguard "$ip" "$node_type" || ((error_count++))
    check_keepalived "$ip" "$node_type" || ((error_count++))
    check_vip "$ip" "$node_type" || ((error_count++))
    check_dns_resolve "$ip" "$node_type" || ((error_count++))
    check_sync_service "$ip" "$node_type" || ((error_count++))
    check_disk_space "$ip" "$node_type" || ((error_count++))
    
    # 输出节点状态摘要
    echo -e "${BLUE}-------------------------------------${NC}"
    if [[ $error_count -eq 0 ]]; then
        echo -e "  节点状态: ${GREEN}✓ 正常${NC}"
    elif [[ $error_count -lt 3 ]]; then
        echo -e "  节点状态: ${YELLOW}⚠ 警告（$error_count个问题）${NC}"
    else
        echo -e "  节点状态: ${RED}✗ 异常（$error_count个问题）${NC}"
    fi
    
    return $error_count
}

# 检查主备同步状态
check_sync_status() {
    echo -e "\n${BLUE}[同步状态检查]${NC}"
    echo -e "${BLUE}-------------------------------------${NC}"
    
    # 检查主节点到备节点的同步是否正常
    echo -n "  主备同步: "
    local sync_test=$(remote_exec "$MASTER_IP" "ssh -o StrictHostKeyChecking=no $SLAVE_IP 'echo 'sync_test'' >/dev/null 2>&1 && echo 'ok' || echo 'fail'" "主节点")
    if [[ "$sync_test" == "ok" ]]; then
        echo -e "${GREEN}✓ 正常${NC}"
        return 0
    else
        echo -e "${RED}✗ 失败${NC}"
        return 1
    fi
}

# 显示系统概览
show_overview() {
    local master_error=$1
    local slave_error=$2
    local sync_error=$3
    
    echo -e "\n${BLUE}=====================================${NC}"
    echo -e "${YELLOW}系统概览${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    # 计算整体状态
    local total_errors=$((master_error + slave_error + sync_error))
    if [[ $total_errors -eq 0 ]]; then
        echo -e "  整体状态: ${GREEN}✓ 健康${NC}"
    elif [[ $total_errors -lt 3 ]]; then
        echo -e "  整体状态: ${YELLOW}⚠ 警告${NC}"
    else
        echo -e "  整体状态: ${RED}✗ 异常${NC}"
    fi
    
    # 显示主备节点VIP状态
    echo -n "  VIP状态: "
    local master_vip=$(remote_exec "$MASTER_IP" "ip addr | grep -q '$VIP' && echo 'bound' || echo 'unbound'" "主节点")
    local slave_vip=$(remote_exec "$SLAVE_IP" "ip addr | grep -q '$VIP' && echo 'bound' || echo 'unbound'" "备节点")
    
    if [[ "$master_vip" == "bound" && "$slave_vip" == "unbound" ]]; then
        echo -e "${GREEN}✓ 主节点活跃${NC}"
    elif [[ "$master_vip" == "unbound" && "$slave_vip" == "bound" ]]; then
        echo -e "${YELLOW}⚠ 备节点活跃${NC}"
    elif [[ "$master_vip" == "bound" && "$slave_vip" == "bound" ]]; then
        echo -e "${RED}✗ 双节点绑定VIP${NC}"
    else
        echo -e "${RED}✗ 无节点绑定VIP${NC}"
    fi
    
    echo -e "${BLUE}=====================================${NC}"
}

# 主检查流程
run_check() {
    local master_error=0
    local slave_error=0
    local sync_error=0
    
    # 清屏（仅在非一次性检查时）
    [[ "$ONCE" != "true" ]] && clear
    
    # 显示检查时间
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}DNSHA 健康检查报告${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "检查时间: $(date +"%Y-%m-%d %H:%M:%S")"
    echo -e "主节点IP: $MASTER_IP"
    echo -e "备节点IP: $SLAVE_IP"
    echo -e "VIP地址: $VIP"
    echo -e "检查间隔: $INTERVAL秒"
    echo -e "${GREEN}=====================================${NC}"
    
    # 检查主节点
    check_node "$MASTER_IP" "主" "master"
    master_error=$?
    
    # 检查备节点
    check_node "$SLAVE_IP" "备" "slave"
    slave_error=$?
    
    # 检查同步状态
    check_sync_status
    sync_error=$?
    
    # 显示系统概览
    show_overview "$master_error" "$slave_error" "$sync_error"
    
    # 记录日志
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local master_status=$([[ $master_error -eq 0 ]] && echo "normal" || echo "abnormal")
    local slave_status=$([[ $slave_error -eq 0 ]] && echo "normal" || echo "abnormal")
    local sync_status=$([[ $sync_error -eq 0 ]] && echo "normal" || echo "abnormal")
    
    log "INFO" "Health check completed - master:$master_status slave:$slave_status sync:$sync_status errors:$total_errors"
}

# 主函数
main() {
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    # 运行检查
    if [[ "$ONCE" == "true" ]]; then
        # 仅检查一次
        run_check
    else
        # 循环检查
        trap "echo -e '\n\n${YELLOW}检测到中断信号，退出健康检查...${NC}'; exit 0" SIGINT SIGTERM
        
        while true; do
            run_check
            echo -e "\n${YELLOW}按 Ctrl+C 退出监控...${NC}"
            sleep "$INTERVAL"
        done
    fi
}

# 脚本入口
main "$@"