#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# 核心入口脚本 - 一键完成主备节点DNS服务安装、容灾配置、VIP绑定、配置同步
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/dnsha_deploy.log"
DEFAULT_VIP="192.168.1.200/24"
DEFAULT_INTERFACE="eth0"
DEFAULT_FAILOVER_MODE="vrrp"

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
    exit 1
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
DNSHA 一键部署脚本

Usage: $0 [OPTIONS]

Options:
  --master-ip, -m <IP>        主节点IP地址（必填）
  --slave-ip, -s <IP>         备节点IP地址（必填）
  --master-pwd, -M <PASS>     主节点root密码（可选，优先使用SSH免密）
  --slave-pwd, -S <PASS>      备节点root密码（可选，优先使用SSH免密）
  --vip, -v <VIP/CIDR>        虚拟IP地址（默认：$DEFAULT_VIP）
  --interface, -i <IFACE>     网卡名称（默认：$DEFAULT_INTERFACE）
  --failover-mode, -f <MODE>  容灾模式：vrrp/haproxy/consul（默认：$DEFAULT_FAILOVER_MODE）
  --config, -c <FILE>         配置文件路径（可选，优先于命令行参数）
  --help, -h                  显示帮助信息

Examples:
  # VRRP模式部署（推荐）
  $0 --master-ip 192.168.1.100 --slave-ip 192.168.1.101 --vip 192.168.1.200/24
  
  # 配置文件部署
  $0 --config dnsha.conf
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
            --master-pwd|-M)
                MASTER_PWD="$2"
                shift 2
                ;;
            --slave-pwd|-S)
                SLAVE_PWD="$2"
                shift 2
                ;;
            --vip|-v)
                VIP="$2"
                shift 2
                ;;
            --interface|-i)
                INTERFACE="$2"
                shift 2
                ;;
            --failover-mode|-f)
                FAILOVER_MODE="$2"
                shift 2
                ;;
            --config|-c)
                CONFIG_FILE="$2"
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

# 读取配置文件
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo_info "读取配置文件：$CONFIG_FILE"
        source "$CONFIG_FILE" 2>/dev/null || echo_error "配置文件格式错误"
        
        # 配置文件变量映射
        MASTER_IP=${master_ip:-$MASTER_IP}
        SLAVE_IP=${slave_ip:-$SLAVE_IP}
        MASTER_PWD=${master_password:-$MASTER_PWD}
        SLAVE_PWD=${slave_password:-$SLAVE_PWD}
        VIP=${vip:-$VIP}
        INTERFACE=${interface:-$INTERFACE}
        FAILOVER_MODE=${failover_mode:-$FAILOVER_MODE}
    fi
}

# 验证参数
validate_params() {
    # 检查必填参数
    [[ -z "$MASTER_IP" ]] && echo_error "必须指定主节点IP（--master-ip）"
    [[ -z "$SLAVE_IP" ]] && echo_error "必须指定备节点IP（--slave-ip）"
    
    # 设置默认值
    VIP=${VIP:-$DEFAULT_VIP}
    INTERFACE=${INTERFACE:-$DEFAULT_INTERFACE}
    FAILOVER_MODE=${FAILOVER_MODE:-$DEFAULT_FAILOVER_MODE}
    
    # 验证容灾模式
    if [[ ! " $FAILOVER_MODE " =~ " (vrrp|haproxy|consul) " ]]; then
        echo_error "容灾模式必须是 vrrp、haproxy 或 consul"
    fi
    
    echo_info "部署参数验证通过："
    echo_info "  主节点IP: $MASTER_IP"
    echo_info "  备节点IP: $SLAVE_IP"
    echo_info "  VIP: $VIP"
    echo_info "  网卡: $INTERFACE"
    echo_info "  容灾模式: $FAILOVER_MODE"
}

# SSH连接测试
ssh_test() {
    local ip=$1
    local pwd=$2
    local node_type=$3
    
    echo_info "测试$node_type节点（$ip）SSH连接..."
    
    if [[ -z "$pwd" ]]; then
        # 免密登录测试
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "echo 'SSH test ok'" >/dev/null 2>&1
    else
        # 密码登录测试
        sshpass -p "$pwd" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$ip" "echo 'SSH test ok'" >/dev/null 2>&1
    fi
    
    if [[ $? -ne 0 ]]; then
        echo_error "$node_type节点（$ip）SSH连接失败，请检查网络或密码"
    fi
    
    echo_success "$node_type节点（$ip）SSH连接成功"
}

# 复制脚本到目标节点
copy_scripts() {
    local ip=$1
    local pwd=$2
    local node_type=$3
    
    echo_info "复制脚本到$node_type节点（$ip）..."
    
    if [[ -z "$pwd" ]]; then
        scp -r "$SCRIPT_DIR"/* root@"$ip":/opt/dnsha/ >/dev/null 2>&1
    else
        sshpass -p "$pwd" scp -r "$SCRIPT_DIR"/* root@"$ip":/opt/dnsha/ >/dev/null 2>&1
    fi
    
    if [[ $? -ne 0 ]]; then
        echo_error "复制脚本到$node_type节点（$ip）失败"
    fi
    
    echo_success "脚本复制到$node_type节点（$ip）成功"
}

# 执行远程命令
remote_exec() {
    local ip=$1
    local pwd=$2
    local cmd=$3
    local node_type=$4
    
    if [[ -z "$pwd" ]]; then
        ssh -o StrictHostKeyChecking=no root@"$ip" "$cmd" 2>&1
    else
        sshpass -p "$pwd" ssh -o StrictHostKeyChecking=no root@"$ip" "$cmd" 2>&1
    fi
}

# 安装DNS服务
install_dns() {
    local ip=$1
    local pwd=$2
    local node_type=$3
    local role=$4
    
    echo_info "在$node_type节点（$ip）安装DNS服务..."
    
    local output=$(remote_exec "$ip" "$pwd" "cd /opt/dnsha && chmod +x *.sh && ./install_dns.sh --role $role" "$node_type")
    
    if [[ $? -ne 0 ]]; then
        echo_error "$node_type节点（$ip）DNS服务安装失败：$output"
    fi
    
    echo_success "$node_type节点（$ip）DNS服务安装成功"
}

# 配置容灾服务
config_failover() {
    local ip=$1
    local pwd=$2
    local node_type=$3
    local role=$4
    
    echo_info "在$node_type节点（$ip）配置容灾服务..."
    
    local output=$(remote_exec "$ip" "$pwd" "cd /opt/dnsha && ./keepalived_config.sh --role $role --vip $VIP --interface $INTERFACE --master-ip $MASTER_IP --slave-ip $SLAVE_IP" "$node_type")
    
    if [[ $? -ne 0 ]]; then
        echo_error "$node_type节点（$ip）容灾服务配置失败：$output"
    fi
    
    echo_success "$node_type节点（$ip）容灾服务配置成功"
}

# 配置同步服务
config_sync() {
    local ip=$1
    local pwd=$2
    local node_type=$3
    local role=$4
    
    echo_info "在$node_type节点（$ip）配置同步服务..."
    
    local output=$(remote_exec "$ip" "$pwd" "cd /opt/dnsha && ./sync_config.sh --role $role --master-ip $MASTER_IP --slave-ip $SLAVE_IP" "$node_type")
    
    if [[ $? -ne 0 ]]; then
        echo_error "$node_type节点（$ip）同步服务配置失败：$output"
    fi
    
    echo_success "$node_type节点（$ip）同步服务配置成功"
}

# 主部署流程
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 一键部署系统${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}基于 SmartDNS + AdGuard Home 构建高可用DNS服务${NC}"
    echo -e "${BLUE}=====================================${NC}\n"
    
    # 解析参数
    parse_args "$@"
    
    # 读取配置文件
    [[ -n "$CONFIG_FILE" ]] && read_config
    
    # 验证参数
    validate_params
    
    # 测试SSH连接
    ssh_test "$MASTER_IP" "$MASTER_PWD" "主"
    ssh_test "$SLAVE_IP" "$SLAVE_PWD" "备"
    
    # 复制脚本到目标节点
    copy_scripts "$MASTER_IP" "$MASTER_PWD" "主"
    copy_scripts "$SLAVE_IP" "$SLAVE_PWD" "备"
    
    # 安装主节点DNS服务
    install_dns "$MASTER_IP" "$MASTER_PWD" "主" "master"
    
    # 安装备节点DNS服务
    install_dns "$SLAVE_IP" "$SLAVE_PWD" "备" "slave"
    
    # 配置主节点容灾服务
    config_failover "$MASTER_IP" "$MASTER_PWD" "主" "master"
    
    # 配置备节点容灾服务
    config_failover "$SLAVE_IP" "$SLAVE_PWD" "备" "slave"
    
    # 配置主节点同步服务
    config_sync "$MASTER_IP" "$MASTER_PWD" "主" "master"
    
    # 配置备节点同步服务
    config_sync "$SLAVE_IP" "$SLAVE_PWD" "备" "slave"
    
    # 验证部署结果
    echo_info "正在验证部署结果..."
    local verify_output=$(remote_exec "$MASTER_IP" "$MASTER_PWD" "cd /opt/dnsha && ./verify_deploy.sh --vip ${VIP%%/*} --role master" "主")
    
    if [[ $? -eq 0 ]]; then
        echo_success "主节点部署验证通过"
    else
        echo_warning "主节点部署验证失败：$verify_output"
    fi
    
    local verify_output_slave=$(remote_exec "$SLAVE_IP" "$SLAVE_PWD" "cd /opt/dnsha && ./verify_deploy.sh --vip ${VIP%%/*} --role slave" "备")
    
    if [[ $? -eq 0 ]]; then
        echo_success "备节点部署验证通过"
    else
        echo_warning "备节点部署验证失败：$verify_output_slave"
    fi
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}🎉 DNSHA 一键部署完成！${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}接下来建议执行：${NC}"
    echo -e "  ./health_check.sh --master-ip $MASTER_IP --slave-ip $SLAVE_IP --once"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"