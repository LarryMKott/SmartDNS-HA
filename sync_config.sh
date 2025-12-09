#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# 配置同步脚本 - 基于inotify + rsync实现实时配置同步
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_sync.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="/opt/dnsha/sync_daemon.sh"
SYSTEMD_SERVICE="/etc/systemd/system/dns_config_sync.service"

# 监控的配置目录
MONITOR_DIRS=("/etc/smartdns" "/opt/AdGuardHome/conf")

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
DNSHA 配置同步脚本

Usage: $0 [OPTIONS]

Options:
  --role, -r <ROLE>        节点角色：master 或 slave（必填）
  --master-ip, -m <IP>     主节点IP地址（必填）
  --slave-ip, -s <IP>      备节点IP地址（必填）
  --interval, -i <SEC>     同步检查间隔（秒，默认1秒）
  --help, -h               显示帮助信息

Examples:
  # 配置主节点同步服务
  $0 --role master --master-ip 192.168.1.100 --slave-ip 192.168.1.101
  
  # 配置备节点同步服务
  $0 --role slave --master-ip 192.168.1.100 --slave-ip 192.168.1.101
EOF
    exit 0
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role|-r)
                ROLE="$2"
                shift 2
                ;;
            --master-ip|-m)
                MASTER_IP="$2"
                shift 2
                ;;
            --slave-ip|-s)
                SLAVE_IP="$2"
                shift 2
                ;;
            --interval|-i)
                INTERVAL="$2"
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
    [[ -z "$ROLE" ]] && echo_error "必须指定节点角色（--role）"
    [[ -z "$MASTER_IP" ]] && echo_error "必须指定主节点IP（--master-ip）"
    [[ -z "$SLAVE_IP" ]] && echo_error "必须指定备节点IP（--slave-ip）"
    
    # 设置默认值
    INTERVAL=${INTERVAL:-1}
    
    echo_info "配置同步参数："
    echo_info "  角色: $ROLE"
    echo_info "  主节点IP: $MASTER_IP"
    echo_info "  备节点IP: $SLAVE_IP"
    echo_info "  同步间隔: $INTERVAL秒"
}

# 安装必要依赖
install_deps() {
    echo_info "安装同步依赖..."
    
    # 检查并安装inotify-tools
    if ! command -v inotifywait >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || echo_error "更新apt源失败"
        apt-get install -y inotify-tools rsync sshpass >/dev/null 2>&1 || echo_error "安装依赖失败"
    fi
    
    echo_success "依赖安装完成"
}

# 配置SSH免密登录
setup_ssh_key() {
    local target_ip=$1
    local node_type=$2
    
    echo_info "配置$node_type节点SSH免密登录..."
    
    # 检查本地密钥
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        echo_info "生成SSH密钥对..."
        ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" >/dev/null 2>&1 || echo_error "生成SSH密钥失败"
    fi
    
    # 复制公钥到目标节点
    ssh-copy-id -i ~/.ssh/id_rsa.pub -o StrictHostKeyChecking=no root@"$target_ip" >/dev/null 2>&1 || {
        # 使用密码方式尝试
        if command -v sshpass >/dev/null 2>&1; then
            echo_warning "免密登录配置失败，尝试使用密码方式..."
        else
            echo_error "$node_type节点SSH免密配置失败，请手动配置"
        fi
    }
    
    echo_success "$node_type节点SSH配置完成"
}

# 创建inotify同步守护脚本
create_sync_daemon() {
    echo_info "创建同步守护脚本..."
    
    # 创建脚本目录
    mkdir -p /opt/dnsha
    
    # 生成同步守护脚本
    cat > "$SYNC_SCRIPT" << 'EOF'
#!/bin/bash
# DNSHA 配置同步守护进程
# 基于inotify + rsync实现实时配置同步

LOG_FILE="/var/log/dnsha_sync_daemon.log"
MASTER_IP="$MASTER_IP"
SLAVE_IP="$SLAVE_IP"
ROLE="$ROLE"

# 监控的配置目录
MONITOR_DIRS=("/etc/smartdns" "/opt/AdGuardHome/conf")

# 日志函数
log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# 同步单个目录
sync_dir() {
    local src=$1
    local dest=$2
    log "INFO" "同步 $src 到 $dest"
    rsync -avz --delete "$src/" "root@$SLAVE_IP:$dest/" 2>&1 | grep -v "sending incremental file list" | grep -v "sent" | grep -v "received" | grep -v "total size"
    if [[ $? -eq 0 ]]; then
        log "INFO" "成功同步 $src 到 $SLAVE_IP:$dest"
    else
        log "ERROR" "同步 $src 到 $SLAVE_IP:$dest 失败"
    fi
}

# 初始同步所有目录
initial_sync() {
    log "INFO" "执行初始同步..."
    for dir in "${MONITOR_DIRS[@]}"; do
        sync_dir "$dir" "$dir"
    done
    log "INFO" "初始同步完成"
}

# 监控目录变化
monitor_dirs() {
    log "INFO" "启动目录监控..."
    
    # 使用inotifywait监控所有目录
    inotifywait -m -r -e modify,create,delete,move --exclude '\.(swp|swx|tmp)$' "${MONITOR_DIRS[@]}" | while read -r directory event file; do
        # 构建完整路径
        local full_path="$directory$file"
        
        # 检查是否是目录
        if [[ -d "$full_path" ]]; then
            continue
        fi
        
        # 查找对应的监控目录
        for dir in "${MONITOR_DIRS[@]}"; do
            if [[ "$full_path" == "$dir"/* ]]; then
                log "INFO" "检测到 $event: $full_path"
                sync_dir "$dir" "$dir"
                break
            fi
        done
    done
}

# 主函数
initial_sync
monitor_dirs
EOF
    
    # 替换脚本中的变量
    sed -i "s/\$MASTER_IP/$MASTER_IP/g" "$SYNC_SCRIPT"
    sed -i "s/\$SLAVE_IP/$SLAVE_IP/g" "$SYNC_SCRIPT"
    sed -i "s/\$ROLE/$ROLE/g" "$SYNC_SCRIPT"
    
    # 赋予执行权限
    chmod +x "$SYNC_SCRIPT"
    
    echo_success "同步守护脚本创建完成: $SYNC_SCRIPT"
}

# 创建系统服务
create_systemd_service() {
    echo_info "创建系统服务..."
    
    cat > "$SYSTEMD_SERVICE" << 'EOF'
[Unit]
Description=DNSHA 配置同步服务
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/opt/dnsha
ExecStart=/bin/bash /opt/dnsha/sync_daemon.sh
Restart=on-failure
RestartSec=5
User=root
Group=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载systemd并启用服务
    systemctl daemon-reload >/dev/null 2>&1 || echo_error "重载systemd失败"
    systemctl enable dns_config_sync >/dev/null 2>&1 || echo_error "启用同步服务失败"
    systemctl restart dns_config_sync >/dev/null 2>&1 || echo_error "启动同步服务失败"
    
    echo_success "系统服务创建完成"
}

# 检查同步服务状态
check_sync_service() {
    echo_info "检查同步服务状态..."
    
    local status=$(systemctl is-active dns_config_sync 2>/dev/null || echo "inactive")
    if [[ "$status" == "active" ]]; then
        echo_success "同步服务运行正常"
        return 0
    else
        echo_warning "同步服务未运行，状态: $status"
        return 1
    fi
}

# 主配置流程
main() {
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    echo -e "\n${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 配置同步服务配置${NC}"
    echo -e "${BLUE}=====================================${NC}"
    
    # 安装依赖
    install_deps
    
    # 配置SSH免密
    setup_ssh_key "$SLAVE_IP" "备"
    
    # 创建同步守护脚本
    create_sync_daemon
    
    # 创建系统服务
    create_systemd_service
    
    # 检查服务状态
    check_sync_service
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo_success "配置同步服务已成功部署！"
    echo_info "同步日志: $LOG_FILE"
    echo_info "守护脚本: $SYNC_SCRIPT"
    echo_info "系统服务: dns_config_sync"
    echo -e "${GREEN}=====================================${NC}"
}

# 脚本入口
main "$@"