#!/bin/bash
# DNSHA - DNS主备容灾一键部署系统
# DNS服务安装脚本 - 安装SmartDNS + AdGuard Home
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 脚本配置
LOG_FILE="/var/log/dnsha_install.log"
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
DNSHA DNS服务安装脚本

Usage: $0 [OPTIONS]

Options:
  --role, -r <ROLE>     节点角色：master 或 slave（必填）
  --help, -h            显示帮助信息

Examples:
  # 安装主节点DNS服务
  $0 --role master
  
  # 安装备节点DNS服务
  $0 --role slave
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
    [[ -z "$ROLE" ]] && echo_error "必须指定节点角色（--role master|slave）"
    [[ "$ROLE" != "master" && "$ROLE" != "slave" ]] && echo_error "节点角色必须是 master 或 slave"
    echo_info "节点角色：$ROLE"
}

# 安装系统依赖
sys_deps_install() {
    echo_info "安装系统依赖..."
    
    apt-get update -y >/dev/null 2>&1 || echo_error "更新apt源失败"
    apt-get install -y --no-install-recommends \
        curl wget git \
        build-essential libssl-dev \
        inotify-tools rsync \
        procps iproute2 \
        iptables-persistent \
        >/dev/null 2>&1 || echo_error "安装系统依赖失败"
    
    echo_success "系统依赖安装完成"
}

# 安装SmartDNS
install_smartdns() {
    echo_info "安装SmartDNS..."
    
    # 检查是否已安装
    if command -v smartdns >/dev/null 2>&1; then
        echo_warning "SmartDNS已安装，跳过安装步骤"
        return 0
    fi
    
    # 克隆SmartDNS仓库
    git clone https://github.com/pymumu/smartdns.git /tmp/smartdns >/dev/null 2>&1 || echo_error "克隆SmartDNS仓库失败"
    
    # 编译安装
    cd /tmp/smartdns || echo_error "进入SmartDNS目录失败"
    make -j$(nproc) >/dev/null 2>&1 || echo_error "编译SmartDNS失败"
    make install >/dev/null 2>&1 || echo_error "安装SmartDNS失败"
    
    # 清理临时文件
    rm -rf /tmp/smartdns
    
    echo_success "SmartDNS安装完成"
}

# 配置SmartDNS
config_smartdns() {
    echo_info "配置SmartDNS..."
    
    # 创建配置目录
    mkdir -p /etc/smartdns/conf.d
    
    # 主配置文件
    cat > /etc/smartdns/smartdns.conf << 'EOF'
# SmartDNS主配置
server-name smartdns
bind-tcp [::]:53
bind [::]:53

# 上游DNS服务器
server 114.114.114.114 -group default
server 114.114.115.115 -group default
server 223.5.5.5 -group aliyun
server 223.6.6.6 -group aliyun
server 8.8.8.8 -group google
server 8.8.4.4 -group google

# 域名规则
speed-check-mode ping,tcp:80
cache-size 10000
cache-ttl-min 60
cache-ttl-max 3600
cache-persist yes
cache-persist-file /var/lib/smartdns/cache.db

# 日志配置
log-level info
log-file /var/log/smartdns.log

# 包含额外配置
include /etc/smartdns/conf.d/*.conf
EOF
    
    # 创建数据目录
    mkdir -p /var/lib/smartdns
    
    # 创建系统服务
    cat > /etc/systemd/system/smartdns.service << 'EOF'
[Unit]
Description=SmartDNS
After=network.target
Wants=network.target

[Service]
Type=forking
PIDFile=/run/smartdns.pid
ExecStart=/usr/local/sbin/smartdns -c /etc/smartdns/smartdns.conf -p /run/smartdns.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载系统服务并启动
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable smartdns >/dev/null 2>&1
    systemctl restart smartdns >/dev/null 2>&1
    
    if [[ $? -ne 0 ]]; then
        echo_error "启动SmartDNS服务失败"
    fi
    
    echo_success "SmartDNS配置完成"
}

# 安装AdGuard Home
install_adguard() {
    echo_info "安装AdGuard Home..."
    
    # 检查是否已安装
    if [[ -f /opt/AdGuardHome/AdGuardHome ]]; then
        echo_warning "AdGuard Home已安装，跳过安装步骤"
        return 0
    fi
    
    # 下载AdGuard Home
    wget -qO- https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_amd64.tar.gz | tar xvz -C /tmp/ >/dev/null 2>&1 || echo_error "下载AdGuard Home失败"
    
    # 安装AdGuard Home
    mkdir -p /opt/AdGuardHome
    mv /tmp/AdGuardHome/AdGuardHome /opt/AdGuardHome/ >/dev/null 2>&1 || echo_error "安装AdGuard Home失败"
    
    # 清理临时文件
    rm -rf /tmp/AdGuardHome
    
    echo_success "AdGuard Home安装完成"
}

# 配置AdGuard Home
config_adguard() {
    echo_info "配置AdGuard Home..."
    
    # 创建数据目录
    mkdir -p /opt/AdGuardHome/conf /opt/AdGuardHome/data
    
    # 主配置文件
    cat > /opt/AdGuardHome/conf/AdGuardHome.yaml << 'EOF'
bind_host: 0.0.0.0
bind_port: 8080

auth_name: admin
auth_pass: "admin123456"

language: zh-cn

http_proxy: ""

dns:
  bind_hosts:
    - 127.0.0.1
  port: 5353
  anonymize_client_ip: false
  ratelimit: 0
  refuse_any: true
  upstream_dns:
    - 127.0.0.1:6053
  upstream_dns_file: ""
  bootstrap_dns:
    - 114.114.114.114
  all_servers: true
  fastest_addr: false
  fastest_timeout: 1000
  allowed_clients:
    - 0.0.0.0/0
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.1
  cache_size: 4194304
  cache_ttl_min: 60
  cache_ttl_max: 86400
  cache_optimistic: true
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    enabled: false
    custom_ip: ""
  max_goroutines: 300
  handle_ddr: true
  ipset:
    enabled: false
    file_path: ""
  filtering_enabled: true
  filters_update_interval: 24
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  ratelimit_whitelist: []
  refuse_any_ip: []

tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 784
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""

filters:
  - enabled: true
    url: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"
    name: "AdGuard DNS filter"
    id: 1
  - enabled: true
    url: "https://adaway.org/hosts.txt"
    name: "AdAway"
    id: 2
  - enabled: true
    url: "https://hosts-file.net/ad_servers.txt"
    name: "hpHosts - Ad and Tracking servers"
    id: 3

user_rules: []

dhcp:
  enabled: false
  interface_name: ""
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false

clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []

log:
  file: /var/log/AdGuardHome.log
  max_size: 100
  max_backups: 3
  compress: false
  local_time: true
  verbose: false

os:
  group: ""
  user: ""
  rlimit_nofile: 0

schema_version: 23
EOF
    
    # 创建系统服务
    cat > /etc/systemd/system/adguardhome.service << 'EOF'
[Unit]
Description=AdGuard Home
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/conf/AdGuardHome.yaml -w /opt/AdGuardHome
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载系统服务并启动
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable adguardhome >/dev/null 2>&1
    systemctl restart adguardhome >/dev/null 2>&1
    
    if [[ $? -ne 0 ]]; then
        echo_error "启动AdGuard Home服务失败"
    fi
    
    echo_success "AdGuard Home配置完成"
}

# 配置防火墙
sys_firewall_config() {
    echo_info "配置防火墙规则..."
    
    # 开放必要端口
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null
    
    # 保存防火墙规则
    netfilter-persistent save >/dev/null 2>&1
    
    echo_success "防火墙配置完成"
}

# 检查服务状态
check_services() {
    echo_info "检查DNS服务状态..."
    
    # 检查SmartDNS
    systemctl is-active smartdns >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo_success "SmartDNS服务运行正常"
    else
        echo_error "SmartDNS服务未运行"
    fi
    
    # 检查AdGuard Home
    systemctl is-active adguardhome >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo_success "AdGuard Home服务运行正常"
    else
        echo_error "AdGuard Home服务未运行"
    fi
    
    # 检查端口占用
    netstat -tuln | grep -E ":53|:8080" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo_success "DNS服务端口（53/8080）已正常监听"
    else
        echo_error "DNS服务端口未正常监听"
    fi
}

# 主安装流程
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA DNS服务安装${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}安装SmartDNS + AdGuard Home DNS服务${NC}"
    echo -e "${BLUE}=====================================${NC}\n"
    
    # 解析参数
    parse_args "$@"
    
    # 验证参数
    validate_params
    
    # 安装系统依赖
    sys_deps_install
    
    # 安装SmartDNS
    install_smartdns
    
    # 配置SmartDNS
    config_smartdns
    
    # 安装AdGuard Home
    install_adguard
    
    # 配置AdGuard Home
    config_adguard
    
    # 配置防火墙
    sys_firewall_config
    
    # 检查服务状态
    check_services
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}🎉 DNS服务安装完成！${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}服务信息：${NC}"
    echo -e "  SmartDNS: 已安装并启动"
    echo -e "  AdGuard Home: 已安装并启动"
    echo -e "  Web管理界面: http://$(hostname -I | awk '{print $1}'):8080"
    echo -e "  管理账号: admin"
    echo -e "  管理密码: admin123456"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"