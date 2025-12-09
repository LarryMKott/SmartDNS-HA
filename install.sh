#!/bin/bash
# DNSHA 一键安装脚本
# 支持 curl xxx | bash 方式一键部署
# 自动检测当地运营商并配置最优DNS
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

# 显示帮助信息
show_help() {
    cat << EOF
DNSHA 一键安装脚本
Usage: $0 [OPTIONS]

Options:
  --ipv4, -4 <IP/CIDR>     设置固定IPv4地址（如：192.168.1.100/24）
  --gateway, -g <IP>        设置IPv4网关
  --ipv6, -6 <IP/CIDR>     设置固定IPv6地址（如：2001:db8::1/64）
  --ipv6-gateway, -G <IP>   设置IPv6网关
  --interface, -i <IFACE>   指定网卡接口（默认自动检测）
  --help, -h               显示帮助信息

Examples:
  # 默认安装（自动检测运营商DNS）
  $0
  
  # 设置固定IPv4
  $0 --ipv4 192.168.1.100/24 --gateway 192.168.1.1
  
  # 设置IPv4+IPv6
  $0 --ipv4 192.168.1.100/24 --gateway 192.168.1.1 \
     --ipv6 2001:db8::1/64 --ipv6-gateway 2001:db8::fffe
EOF
    exit 0
}

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
    echo -e "[$timestamp] [$level] $msg"
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

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ipv4|-4)
                IPV4_ADDR="$2"
                shift 2
                ;;
            --gateway|-g)
                IPV4_GATEWAY="$2"
                shift 2
                ;;
            --ipv6|-6)
                IPV6_ADDR="$2"
                shift 2
                ;;
            --ipv6-gateway|-G)
                IPV6_GATEWAY="$2"
                shift 2
                ;;
            --interface|-i)
                NET_INTERFACE="$2"
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

# 检测当前系统
detect_system() {
    echo_info "检测当前系统..."
    
    if [[ -f /etc/debian_version ]]; then
        local debian_version=$(cat /etc/debian_version | cut -d '.' -f 1)
        if [[ $debian_version -lt 13 ]]; then
            echo_error "当前系统版本太低，需要Debian 13+"
        fi
        echo_success "当前系统：Debian $debian_version，符合要求"
        return 0
    else
        echo_error "当前系统不是Debian，不支持一键安装"
    fi
}

# 检测主要网卡
detect_interface() {
    echo_info "检测主要网卡..."
    
    # 如果用户指定了网卡，直接使用
    if [[ -n "$NET_INTERFACE" ]]; then
        echo_success "使用指定网卡：$NET_INTERFACE"
        return 0
    fi
    
    # 自动检测主要网卡（默认网关所在的网卡）
    local default_interface=$(ip route show default | awk '{print $5}' | head -1)
    if [[ -n "$default_interface" ]]; then
        NET_INTERFACE="$default_interface"
        echo_success "自动检测到主要网卡：$NET_INTERFACE"
        return 0
    fi
    
    # 备用检测方式
    default_interface=$(ip -o -4 addr show | grep -v 'lo:' | head -1 | awk '{print $2}')
    if [[ -n "$default_interface" ]]; then
        NET_INTERFACE="$default_interface"
        echo_success "备用检测到网卡：$NET_INTERFACE"
        return 0
    fi
    
    echo_error "无法检测到网卡，请使用 --interface 参数指定"
}

# 设置固定IPv4地址
set_ipv4() {
    local ipv4=$1
    local gateway=$2
    local interface=$3
    
    echo_info "设置固定IPv4地址：$ipv4，网关：$gateway，网卡：$interface"
    
    # 获取当前网络配置文件
    local netplan_files=($(ls /etc/netplan/*.yaml 2>/dev/null))
    local netplan_file
    
    if [[ ${#netplan_files[@]} -gt 0 ]]; then
        # 使用netplan配置
        netplan_file="${netplan_files[0]}"
        echo_info "使用netplan配置文件：$netplan_file"
        
        # 备份当前配置
        cp "$netplan_file" "${netplan_file}.bak"
        
        # 生成新的netplan配置
        cat > "$netplan_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      addresses: [$ipv4]
      gateway4: $gateway
      nameservers:
        addresses: [114.114.114.114, 8.8.8.8]
EOF
        
        # 应用配置
        netplan apply >/dev/null 2>&1 || echo_error "netplan apply失败"
        echo_success "IPv4地址设置完成"
        return 0
    else
        # 使用传统方式配置
        echo_info "使用传统方式配置网络"
        
        # 备份当前配置
        cp /etc/network/interfaces "/etc/network/interfaces.bak"
        
        # 生成新的网络配置
        cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
    address $ipv4
    gateway $gateway
    dns-nameservers 114.114.114.114 8.8.8.8
EOF
        
        # 重启网络服务
        systemctl restart networking >/dev/null 2>&1 || echo_error "重启网络服务失败"
        echo_success "IPv4地址设置完成"
        return 0
    fi
}

# 设置固定IPv6地址
set_ipv6() {
    local ipv6=$1
    local gateway=$2
    local interface=$3
    
    echo_info "设置固定IPv6地址：$ipv6，网关：$gateway，网卡：$interface"
    
    # 获取当前网络配置文件
    local netplan_files=($(ls /etc/netplan/*.yaml 2>/dev/null))
    local netplan_file
    
    if [[ ${#netplan_files[@]} -gt 0 ]]; then
        # 使用netplan配置
        netplan_file="${netplan_files[0]}"
        
        # 检查是否已包含IPv6配置
        if grep -q "addresses" "$netplan_file" && grep -q "gateway4" "$netplan_file"; then
            # 修改现有配置，添加IPv6
            sed -i "/addresses:/ s/\]$/, $ipv6\]/" "$netplan_file"
            sed -i "/gateway4:/ a\      gateway6: $gateway" "$netplan_file"
        else
            # 创建新的配置
            cat > "$netplan_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      addresses: [$ipv6]
      gateway6: $gateway
      nameservers:
        addresses: [2001:4860:4860::8888, 2001:4860:4860::8844]
EOF
        fi
        
        # 应用配置
        netplan apply >/dev/null 2>&1 || echo_error "netplan apply失败"
        echo_success "IPv6地址设置完成"
        return 0
    else
        # 使用传统方式配置
        # 备份当前配置
        cp /etc/network/interfaces "/etc/network/interfaces.bak"
        
        # 添加IPv6配置
        cat >> /etc/network/interfaces << EOF

iface $interface inet6 static
    address $ipv6
    gateway $gateway
    dns-nameservers 2001:4860:4860::8888 2001:4860:4860::8844
EOF
        
        # 重启网络服务
        systemctl restart networking >/dev/null 2>&1 || echo_error "重启网络服务失败"
        echo_success "IPv6地址设置完成"
        return 0
    fi
}

# 检测当地运营商
detect_isp() {
    echo_info "检测当地运营商..."
    
    # 使用ipinfo.io API检测运营商
    local isp=$(curl -s ipinfo.io/org | cut -d ' ' -f 2- 2>/dev/null)
    
    if [[ -z "$isp" ]]; then
        # 使用备用API
        isp=$(curl -s api.myip.com | grep -oP '(?<=isp":").*?(?=")' 2>/dev/null || echo "Unknown")
    fi
    
    echo_success "检测到运营商：$isp"
    echo "$isp" > /tmp/dnsha_isp.txt
}

# 根据运营商配置DNS
get_isp_dns() {
    local isp=$1
    
    # 运营商DNS映射表
    declare -A isp_dns_map
    
    # 中国电信
    isp_dns_map["China Telecom"]="202.96.134.133 202.96.128.166"
    isp_dns_map["中国电信"]="202.96.134.133 202.96.128.166"
    isp_dns_map["电信"]="202.96.134.133 202.96.128.166"
    
    # 中国联通
    isp_dns_map["China Unicom"]="221.130.33.52 221.130.33.50"
    isp_dns_map["中国联通"]="221.130.33.52 221.130.33.50"
    isp_dns_map["联通"]="221.130.33.52 221.130.33.50"
    
    # 中国移动
    isp_dns_map["China Mobile"]="211.136.17.107 211.136.192.6"
    isp_dns_map["中国移动"]="211.136.17.107 211.136.192.6"
    isp_dns_map["移动"]="211.136.17.107 211.136.192.6"
    
    # 教育网
    isp_dns_map["CERNET"]="202.112.20.131 202.112.20.132"
    isp_dns_map["教育网"]="202.112.20.131 202.112.20.132"
    
    # 默认DNS
    isp_dns_map["Default"]="114.114.114.114 114.114.115.115 8.8.8.8 8.8.4.4"
    
    # 匹配运营商
    for key in "${!isp_dns_map[@]}"; do
        if [[ "$isp" =~ "$key" ]]; then
            echo_success "使用${key}DNS：${isp_dns_map[$key]}"
            echo "${isp_dns_map[$key]}" > /tmp/dnsha_isp_dns.txt
            return 0
        fi
    done
    
    # 默认DNS
    echo_warning "未识别运营商，使用默认DNS"
    echo "${isp_dns_map["Default"]}" > /tmp/dnsha_isp_dns.txt
    return 0
}

# 一键安装DNSHA
install_dnsha() {
    echo_info "开始安装DNSHA..."
    
    # 安装依赖
    echo_info "安装系统依赖..."
    apt-get update -y >/dev/null 2>&1 || echo_error "更新apt源失败"
    apt-get install -y --no-install-recommends \
        curl wget git build-essential libssl-dev \
        inotify-tools rsync keepalived haproxy \
        procps iproute2 iptables-persistent \
        >/dev/null 2>&1 || echo_error "安装依赖失败"
    
    # 克隆仓库
    echo_info "克隆DNSHA仓库..."
    if [[ -d /opt/dnsha ]]; then
        rm -rf /opt/dnsha
    fi
    git clone https://github.com/LarryMKott/SmartDNS-HA.git /opt/dnsha >/dev/null 2>&1 || {
        # 备用下载方式
        echo_info "使用备用方式下载..."
        mkdir -p /opt/dnsha
        cd /opt/dnsha || echo_error "进入目录失败"
        wget -qO- https://github.com/LarryMKott/SmartDNS-HA/archive/refs/heads/master.zip | unzip -q - && mv SmartDNS-HA-master/* . && rm -rf SmartDNS-HA-master
    }
    
    # 赋予执行权限
    chmod +x /opt/dnsha/*.sh
    
    echo_success "DNSHA安装完成，安装目录：/opt/dnsha"
}

# 主函数
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 一键安装脚本${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "基于 SmartDNS + AdGuard Home 构建高可用DNS服务"
    echo -e "支持 VRRP/Haproxy/Consul 三种容灾模式"
    echo -e "自动检测当地运营商并配置最优DNS"
    echo -e "支持设置固定IPv4/IPv6地址"
    echo -e "${BLUE}=====================================${NC}\n"
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo_error "请以root用户运行此脚本"
    fi
    
    # 解析命令行参数
    parse_args "$@"
    
    # 检测系统
    detect_system
    
    # 检测网卡
    detect_interface
    
    # 设置IPv4（如果提供了）
    if [[ -n "$IPV4_ADDR" && -n "$IPV4_GATEWAY" ]]; then
        set_ipv4 "$IPV4_ADDR" "$IPV4_GATEWAY" "$NET_INTERFACE"
    elif [[ -n "$IPV4_ADDR" || -n "$IPV4_GATEWAY" ]]; then
        echo_error "设置IPv4时必须同时提供IPv4地址和网关"
    fi
    
    # 设置IPv6（如果提供了）
    if [[ -n "$IPV6_ADDR" && -n "$IPV6_GATEWAY" ]]; then
        set_ipv6 "$IPV6_ADDR" "$IPV6_GATEWAY" "$NET_INTERFACE"
    elif [[ -n "$IPV6_ADDR" || -n "$IPV6_GATEWAY" ]]; then
        echo_error "设置IPv6时必须同时提供IPv6地址和网关"
    fi
    
    # 检测运营商
    detect_isp
    local isp=$(cat /tmp/dnsha_isp.txt)
    
    # 配置DNS
    get_isp_dns "$isp"
    local dns_servers=$(cat /tmp/dnsha_isp_dns.txt)
    
    # 安装DNSHA
    install_dnsha
    
    echo -e "\n${GREEN}=====================================${NC}"
    echo -e "${GREEN}🎉 DNSHA 一键安装完成！${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${YELLOW}安装信息：${NC}"
    echo -e "  安装目录：/opt/dnsha"
    echo -e "  检测到运营商：$isp"
    echo -e "  配置的DNS：$dns_servers"
    
    # 显示网络配置信息
    if [[ -n "$IPV4_ADDR" ]]; then
        echo -e "  IPv4地址：$IPV4_ADDR，网关：$IPV4_GATEWAY"
    fi
    if [[ -n "$IPV6_ADDR" ]]; then
        echo -e "  IPv6地址：$IPV6_ADDR，网关：$IPV6_GATEWAY"
    fi
    echo -e "  网卡：$NET_INTERFACE"
    
    echo -e "\n${YELLOW}接下来可以执行：${NC}"
    echo -e "  # 一键部署主备节点"
    echo -e "  /opt/dnsha/deploy_dns.sh --help"
    echo -e "\n  # 查看健康检查"
    echo -e "  /opt/dnsha/health_check.sh --help"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"