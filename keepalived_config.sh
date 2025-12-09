#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# VRRP配置脚本 - 配置Keepalived实现VIP漂移
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_keepalived.log"
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
DNSHA Keepalived配置脚本

Usage: $0 [OPTIONS]

Options:
  --role, -r <ROLE>           节点角色：master 或 slave（必填）
  --vip, -v <VIP/CIDR>        虚拟IP地址（必填，如：192.168.1.200/24）
  --interface, -i <IFACE>     网卡名称（必填，如：eth0）
  --master-ip, -m <IP>        主节点IP地址（必填）
  --slave-ip, -s <IP>         备节点IP地址（必填）
  --priority, -p <NUM>        优先级（主节点默认100，备节点默认90）
  --failover-mode, -f <MODE>  容灾模式：vrrp（默认）、haproxy、consul
  --help, -h                  显示帮助信息

Examples:
  # 配置主节点Keepalived
  $0 --role master --vip 192.168.1.200/24 --interface eth0 --master-ip 192.168.1.100 --slave-ip 192.168.1.101
  
  # 配置备节点Keepalived
  $0 --role slave --vip 192.168.1.200/24 --interface eth0 --master-ip 192.168.1.100 --slave-ip 192.168.1.101
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
            --vip|-v)
                VIP="$2"
                shift 2
                ;;
            --interface|-i)
                INTERFACE="$2"
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
            --priority|-p)
                PRIORITY="$2"
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
    # 检查必填参数
    [[ -z "$ROLE" ]] && echo_error "必须指定节点角色（--role）"
    [[ -z "$VIP" ]] && echo_error "必须指定虚拟IP（--vip）"
    [[ -z "$INTERFACE" ]] && echo_error "必须指定网卡名称（--interface）"
    [[ -z "$MASTER_IP" ]] && echo_error "必须指定主节点IP（--master-ip）"
    [[ -z "$SLAVE_IP" ]] && echo_error "必须指定备节点IP（--slave-ip）"
    
    # 验证角色
    [[ "$ROLE" != "master" && "$ROLE" != "slave" ]] && echo_error "节点角色必须是 master 或 slave"
    
    # 设置默认值
    FAILOVER_MODE=${FAILOVER_MODE:-"vrrp"}
    
    # 设置优先级
    if [[ "$ROLE" == "master" ]]; then
        PRIORITY=${PRIORITY:-100}
    else
        PRIORITY=${PRIORITY:-90}
    fi
    
    echo_info "Keepalived配置参数："
    echo_info "  角色: $ROLE"
    echo_info "  VIP: $VIP"
    echo_info "  网卡: $INTERFACE"
    echo_info "  主节点IP: $MASTER_IP"
    echo_info "  备节点IP: $SLAVE_IP"
    echo_info "  优先级: $PRIORITY"
    echo_info "  容灾模式: $FAILOVER_MODE"
}

# 安装Keepalived
install_keepalived() {
    echo_info "安装Keepalived..."
    
    # 检查是否已安装
    if command -v keepalived >/dev/null 2>&1; then
        echo_warning "Keepalived已安装，跳过安装步骤"
        return 0
    fi
    
    # 安装Keepalived
    apt-get update -y >/dev/null 2>&1 || echo_error "更新apt源失败"
    apt-get install -y keepalived >/dev/null 2>&1 || echo_error "安装Keepalived失败"
    
    echo_success "Keepalived安装完成"
}

# 生成Keepalived配置文件
generate_keepalived_config() {
    echo_info "生成Keepalived配置文件..."
    
    # 创建配置目录
    mkdir -p /etc/keepalived
    
    # 主配置文件
    cat > /etc/keepalived/keepalived.conf << EOF
! Configuration File for keepalived

global_defs {
    notification_email {
        admin@example.com
    }
    notification_email_from keepalived@example.com
    smtp_server 127.0.0.1
    smtp_connect_timeout 30
    router_id DNSHA_${ROLE^^}
    vrrp_skip_check_adv_addr
    vrrp_strict
    vrrp_garp_interval 0
    vrrp_gna_interval 0
}

# DNS服务健康检查脚本
vrrp_script check_dns_service {
    script "/etc/keepalived/check_dns.sh"
    interval 2
    weight -10
    fall 2
    rise 2
}

# VRRP实例配置
vrrp_instance VI_1 {
    state ${ROLE^^}
    interface $INTERFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass dnsha123
    }
    virtual_ipaddress {
        $VIP
    }
    
    # 健康检查
    track_script {
        check_dns_service
    }
    
    # 通知脚本
    notify_master "/etc/keepalived/notify.sh master"
    notify_backup "/etc/keepalived/notify.sh backup"
    notify_fault "/etc/keepalived/notify.sh fault"
    notify_stop "/etc/keepalived/notify.sh stop"
}
EOF
    
    echo_success "Keepalived配置文件生成完成"
}

# 创建DNS健康检查脚本
create_health_check_script() {
    echo_info "创建DNS健康检查脚本..."
    
    cat > /etc/keepalived/check_dns.sh << 'EOF'
#!/bin/bash
# DNSHA DNS服务健康检查脚本

# 检查SmartDNS服务
if ! systemctl is-active smartdns >/dev/null 2>&1; then
    exit 1
fi

# 检查AdGuard Home服务
if ! systemctl is-active adguardhome >/dev/null 2>&1; then
    exit 1
fi

# 检查DNS解析功能
if ! dig @127.0.0.1 www.baidu.com +short +timeout=2 >/dev/null 2>&1; then
    exit 1
fi

# 检查端口监听
if ! netstat -tuln | grep -E ':53|:8080' >/dev/null 2>&1; then
    exit 1
fi

exit 0
EOF
    
    # 赋予执行权限
    chmod +x /etc/keepalived/check_dns.sh
    
    echo_success "DNS健康检查脚本创建完成"
}

# 创建通知脚本
create_notify_script() {
    echo_info "创建VRRP通知脚本..."
    
    cat > /etc/keepalived/notify.sh << 'EOF'
#!/bin/bash
# DNSHA VRRP通知脚本

TYPE=$1
VIP="$2"
LOG_FILE="/var/log/keepalived_notify.log"

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

case $TYPE in
    master)
        log "INFO" "节点切换为主节点，VIP已绑定"
        # 主节点激活时执行的命令
        ;;
    backup)
        log "INFO" "节点切换为备节点，VIP已释放"
        # 备节点激活时执行的命令
        ;;
    fault)
        log "ERROR" "节点故障，VIP已释放"
        # 节点故障时执行的命令
        ;;
    stop)
        log "INFO" "Keepalived停止，VIP已释放"
        # Keepalived停止时执行的命令
        ;;
    *)
        log "ERROR" "未知通知类型: $TYPE"
        ;;
esac
EOF
    
    # 赋予执行权限
    chmod +x /etc/keepalived/notify.sh
    
    echo_success "VRRP通知脚本创建完成"
}

# 配置Haproxy模式（负载均衡）
config_haproxy() {
    echo_info "配置Haproxy模式..."
    
    # 检查是否已安装
    if ! command -v haproxy >/dev/null 2>&1; then
        apt-get install -y haproxy >/dev/null 2>&1 || echo_error "安装Haproxy失败"
    fi
    
    # 生成Haproxy配置
    cat > /etc/haproxy/haproxy.cfg << EOF
# DNSHA Haproxy配置

global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    
    # Default SSL material locations
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    
    # Default ciphers to use on SSL-enabled listening sockets.
    # For more information, see ciphers(1SSL). This list is from:
    #  https://hynek.me/articles/hardening-your-web-servers-ssl-ciphers/
    # An alternative list with additional directives can be obtained from
    #  https://mozilla.github.io/server-side-tls/ssl-config-generator/?server=haproxy
    ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
    ssl-default-bind-options no-sslv3

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# DNS负载均衡配置
frontend dns_frontend
    bind *:53
    mode tcp
    default_backend dns_backend

backend dns_backend
    mode tcp
    balance roundrobin
    option tcp-check
    tcp-check send QUERY\ example.com\ IN\ A\ \r\n
    # 主节点
    server master $MASTER_IP:53 check inter 2s rise 2 fall 2
    # 备节点
    server slave $SLAVE_IP:53 check inter 2s rise 2 fall 2

# Web管理界面
listen stats
    bind *:8081
    stats enable
    stats uri /haproxy-stats
    stats auth admin:admin123456
EOF
    
    # 重启Haproxy服务
    systemctl restart haproxy >/dev/null 2>&1 || echo_error "重启Haproxy服务失败"
    systemctl enable haproxy >/dev/null 2>&1 || echo_error "设置Haproxy开机自启失败"
    
    echo_success "Haproxy模式配置完成"
}

# 配置Consul模式（服务发现）
config_consul() {
    echo_info "配置Consul模式..."
    
    # 检查是否已安装
    if ! command -v consul >/dev/null 2>&1; then
        echo_warning "Consul未安装，跳过Consul配置"
        return 0
    fi
    
    # 生成Consul配置
    mkdir -p /etc/consul.d
    
    cat > /etc/consul.d/consul_server.json << EOF
{
  "datacenter": "dnsha-dc1",
  "data_dir": "/var/lib/consul",
  "log_level": "INFO",
  "node_name": "dnsha-$ROLE",
  "server": true,
  "bootstrap_expect": 2,
  "bind_addr": "$(hostname -I | awk '{print $1}')",
  "client_addr": "0.0.0.0",
  "retry_join": ["$MASTER_IP", "$SLAVE_IP"],
  "ui_config": {
    "enabled": true
  }
}
EOF
    
    # 重启Consul服务
    systemctl restart consul >/dev/null 2>&1 || echo_warning "重启Consul服务失败"
    systemctl enable consul >/dev/null 2>&1 || echo_warning "设置Consul开机自启失败"
    
    echo_success "Consul模式配置完成"
}

# 启动并启用Keepalived服务
start_keepalived_service() {
    echo_info "启动Keepalived服务..."
    
    # 重载系统服务
    systemctl daemon-reload >/dev/null 2>&1
    
    # 启动服务
    systemctl restart keepalived >/dev/null 2>&1 || echo_error "启动Keepalived服务失败"
    
    # 设置开机自启
    systemctl enable keepalived >/dev/null 2>&1 || echo_error "设置Keepalived开机自启失败"
    
    echo_success "Keepalived服务已启动并设置开机自启"
}

# 验证Keepalived配置
verify_keepalived_config() {
    echo_info "验证Keepalived配置..."
    
    # 检查配置文件语法
    keepalived -t -f /etc/keepalived/keepalived.conf >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo_error "Keepalived配置文件语法错误"
    fi
    
    # 检查服务状态
    sleep 2
    systemctl is-active keepalived >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo_success "Keepalived服务运行正常"
    else
        echo_error "Keepalived服务运行异常"
    fi
    
    echo_success "Keepalived配置验证通过"
}

# 主配置流程
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA Keepalived配置${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}配置VRRP容灾，实现VIP漂移${NC}"
    echo -e "${BLUE}=====================================${NC}\n"
    
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    # 安装Keepalived
    install_keepalived
    
    # 根据容灾模式配置
    case "$FAILOVER_MODE" in
        vrrp)
            # 生成Keepalived配置文件
            generate_keepalived_config
            
            # 创建健康检查脚本
            create_health_check_script
            
            # 创建通知脚本
            create_notify_script
            
            # 启动服务
            start_keepalived_service
            
            # 验证配置
            verify_keepalived_config
            ;;
        haproxy)
            # 配置Haproxy模式
            config_haproxy
            ;;
        consul)
            # 配置Consul模式
            config_consul
            ;;
        *)
            echo_error "未知容灾模式：$FAILOVER_MODE"
            ;;
    esac
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}🎉 Keepalived配置完成！${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}配置信息：${NC}"
    echo -e "  配置文件: /etc/keepalived/keepalived.conf"
    echo -e "  日志文件: /var/log/keepalived.log"
    echo -e "  健康检查: /etc/keepalived/check_dns.sh"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"