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

# 设置IPv6地址（支持固定IP和DHCP）
set_ipv6() {
    local interface=$1
    local ipv6=$2
    local gateway=$3
    local mode=$4
    
    if [[ "$mode" == "dhcp" || -z "$ipv6" ]]; then
        echo_info "设置IPv6 DHCP自动获取，网卡：$interface"
        
        # 获取当前网络配置文件
        local netplan_files=($(ls /etc/netplan/*.yaml 2>/dev/null))
        local netplan_file
        
        if [[ ${#netplan_files[@]} -gt 0 ]]; then
            # 使用netplan配置
            netplan_file="${netplan_files[0]}"
            
            # 检查是否已包含IPv6配置
            if grep -q "addresses" "$netplan_file"; then
                # 修改现有配置，启用IPv6 DHCP
                sed -i "/addresses:/a\      dhcp6: true" "$netplan_file"
                sed -i "/gateway6:/d" "$netplan_file" 2>/dev/null
            else
                # 创建新的配置
                cat > "$netplan_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: true
      dhcp6: true
EOF
            fi
            
            # 应用配置
            netplan apply >/dev/null 2>&1 || echo_error "netplan apply失败"
            echo_success "IPv6 DHCP设置完成"
            return 0
        else
            # 使用传统方式配置
            # 备份当前配置
            cp /etc/network/interfaces "/etc/network/interfaces.bak"
            
            # 添加IPv6 DHCP配置
            cat >> /etc/network/interfaces << EOF

iface $interface inet6 dhcp
EOF
            
            # 重启网络服务
            systemctl restart networking >/dev/null 2>&1 || echo_error "重启网络服务失败"
            echo_success "IPv6 DHCP设置完成"
            return 0
        fi
    else
        # 固定IPv6地址配置
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
                sed -i "/dhcp6:/d" "$netplan_file" 2>/dev/null
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
            echo_success "固定IPv6地址设置完成"
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
            echo_success "固定IPv6地址设置完成"
            return 0
        fi
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

# 交互式设置IP
interactive_ip_setup() {
    echo_info "进入交互式IP配置模式..."
    
    # 询问是否设置固定IP
    read -p "是否设置固定IP？(y/n) [n]: " set_fixed_ip
    set_fixed_ip=${set_fixed_ip:-n}
    
    if [[ "$set_fixed_ip" == "y" || "$set_fixed_ip" == "Y" ]]; then
        # 询问IPv4设置
        read -p "是否设置固定IPv4？(y/n) [y]: " set_ipv4_flag
        set_ipv4_flag=${set_ipv4_flag:-y}
        
        if [[ "$set_ipv4_flag" == "y" || "$set_ipv4_flag" == "Y" ]]; then
            # 获取当前IPv4信息
            local current_ipv4=$(ip -o -4 addr show "$NET_INTERFACE" | awk '{print $4}' | head -1)
            local current_gateway=$(ip route show default | grep "$NET_INTERFACE" | awk '{print $3}' | head -1)
            
            read -p "请输入IPv4地址（CIDR格式，如：192.168.1.100/24）[$current_ipv4]: " IPV4_ADDR
            IPV4_ADDR=${IPV4_ADDR:-$current_ipv4}
            
            read -p "请输入IPv4网关 [$current_gateway]: " IPV4_GATEWAY
            IPV4_GATEWAY=${IPV4_GATEWAY:-$current_gateway}
        fi
        
        # 询问IPv6设置方式
        echo "IPv6获取方式："
        echo "1. 固定IP地址"
        echo "2. DHCP自动获取"
        read -p "请选择IPv6获取方式 (1-2) [2]: " ipv6_mode
        ipv6_mode=${ipv6_mode:-2}
        
        if [[ $ipv6_mode -eq 1 ]]; then
            # 固定IPv6设置
            # 获取当前IPv6信息
            local current_ipv6=$(ip -o -6 addr show "$NET_INTERFACE" | grep -v 'fe80::' | awk '{print $4}' | head -1)
            
            read -p "请输入IPv6地址（CIDR格式，如：2001:db8::1/64）[$current_ipv6]: " IPV6_ADDR
            IPV6_ADDR=${IPV6_ADDR:-$current_ipv6}
            
            # IPv6网关通常是网络前缀+1或fffe
            local ipv6_prefix=$(echo "$IPV6_ADDR" | cut -d ':' -f 1-5)
            local default_ipv6_gateway="${ipv6_prefix}::fffe"
            read -p "请输入IPv6网关 [$default_ipv6_gateway]: " IPV6_GATEWAY
            IPV6_GATEWAY=${IPV6_GATEWAY:-$default_ipv6_gateway}
            
            # 询问IPv6 DDNS绑定
            read -p "是否为IPv6绑定DDNS域名？(y/n) [y]: " set_ddns_flag
            set_ddns_flag=${set_ddns_flag:-y}
            
            if [[ "$set_ddns_flag" == "y" || "$set_ddns_flag" == "Y" ]]; then
                setup_ipv6_ddns
            fi
        else
            # DHCP方式
            echo_info "使用IPv6 DHCP自动获取地址"
            IPV6_MODE="dhcp"
            
            # 询问IPv6 DDNS绑定
            read -p "是否为IPv6绑定DDNS域名？(y/n) [y]: " set_ddns_flag
            set_ddns_flag=${set_ddns_flag:-y}
            
            if [[ "$set_ddns_flag" == "y" || "$set_ddns_flag" == "Y" ]]; then
                setup_ipv6_ddns
            fi
        fi
    fi
}

# 设置IPv6 DDNS
auth_cloudflare_ddns() {
    local api_token=$1
    local zone_id=$2
    local record_name=$3
    local ipv6=$4
    
    echo_info "使用Cloudflare DDNS更新IPv6记录：$record_name -> $ipv6"
    
    # 获取现有记录
    local record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?name=$record_name&type=AAAA" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json")
    
    local record_id=$(echo "$record" | grep -oP '(?<="id":")[^"]+' | head -1)
    
    if [[ -n "$record_id" ]]; then
        # 更新记录
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"AAAA\",\"name\":\"$record_name\",\"content\":\"$ipv6\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1
    else
        # 创建记录
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
            -H "Authorization: Bearer $api_token" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"AAAA\",\"name\":\"$record_name\",\"content\":\"$ipv6\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1
    fi
    
    if [[ $? -eq 0 ]]; then
        echo_success "Cloudflare DDNS更新成功"
        return 0
    else
        echo_error "Cloudflare DDNS更新失败"
        return 1
    fi
}

# 设置IPv6 DDNS
auth_aliyun_ddns() {
    local access_key_id=$1
    local access_key_secret=$2
    local domain=$3
    local record_type=$4
    local value=$5
    local rr=$6
    
    echo_info "使用阿里云DDNS更新记录：$rr.$domain -> $value"
    
    # 这里需要实现阿里云DDNS API调用
    # 由于阿里云API签名复杂，这里简化处理
    echo_warning "阿里云DDNS功能正在开发中"
    return 0
}

# 交互式设置IPv6 DDNS
setup_ipv6_ddns() {
    echo_info "开始配置IPv6 DDNS..."
    
    # 只支持Cloudflare
    echo "使用Cloudflare DDNS服务"
    
    # 获取当前IPv6地址（不带CIDR）
    local current_ipv6
    if [[ -n "$IPV6_ADDR" ]]; then
        current_ipv6=$(echo "$IPV6_ADDR" | cut -d '/' -f 1)
    else
        # 如果是DHCP模式，获取当前IPv6地址
        current_ipv6=$(ip -o -6 addr show "$NET_INTERFACE" | grep -v 'fe80::' | awk '{print $4}' | cut -d '/' -f 1 | head -1)
    fi
    
    # Cloudflare配置
    read -p "请输入Cloudflare API Token: " CLOUDFLARE_TOKEN
    read -p "请输入Zone ID: " CLOUDFLARE_ZONE_ID
    read -p "请输入域名 (如: example.com): " CLOUDFLARE_DOMAIN
    read -p "请输入记录名 (如: ipv6): " CLOUDFLARE_RECORD_NAME
    
    # 构建完整记录名
    local full_record_name="${CLOUDFLARE_RECORD_NAME}.${CLOUDFLARE_DOMAIN}"
    
    # 立即更新一次DDNS
    auth_cloudflare_ddns "$CLOUDFLARE_TOKEN" "$CLOUDFLARE_ZONE_ID" "$full_record_name" "$current_ipv6"
    
    # 创建DDNS更新脚本
    create_cloudflare_ddns_script "$CLOUDFLARE_TOKEN" "$CLOUDFLARE_ZONE_ID" "$full_record_name"
}

# 创建Cloudflare DDNS自动更新脚本
create_cloudflare_ddns_script() {
    local token=$1
    local zone_id=$2
    local record_name=$3
    
    echo_info "创建Cloudflare DDNS自动更新脚本..."
    
    # 创建DDNS更新脚本
    cat > /opt/dnsha/cloudflare_ddns.sh << EOF
#!/bin/bash
# DNSHA Cloudflare DDNS自动更新脚本
# 用于定期更新IPv6地址到Cloudflare

# 配置参数
LOG_FILE="/var/log/cloudflare_ddns.log"
INTERFACE="$NET_INTERFACE"
CLOUDFLARE_TOKEN="$token"
CLOUDFLARE_ZONE_ID="$zone_id"
CLOUDFLARE_RECORD_NAME="$record_name"

# 日志函数
log() {
    local level=\$1
    local msg=\$2
    local timestamp=\$(date +"%Y-%m-%d %H:%M:%S")
    echo "[\$timestamp] [\$level] \$msg" >> "\$LOG_FILE"
}

# 获取当前IPv6地址
get_current_ipv6() {
    ip -o -6 addr show "\$INTERFACE" | grep -v 'fe80::' | awk '{print \$4}' | cut -d '/' -f 1 | head -1
}

# 获取当前Cloudflare记录
get_cloudflare_record() {
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/\${CLOUDFLARE_ZONE_ID}/dns_records?name=\${CLOUDFLARE_RECORD_NAME}&type=AAAA" \
        -H "Authorization: Bearer \${CLOUDFLARE_TOKEN}" \
        -H "Content-Type: application/json"
}

# 更新Cloudflare记录
update_cloudflare_record() {
    local record_id=\$1
    local ipv6=\$2
    
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/\${CLOUDFLARE_ZONE_ID}/dns_records/\${record_id}" \
        -H "Authorization: Bearer \${CLOUDFLARE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"AAAA\",\"name\":\"\${CLOUDFLARE_RECORD_NAME}\",\"content\":\"\${ipv6}\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1
    
    return \$?
}

# 创建Cloudflare记录
create_cloudflare_record() {
    local ipv6=\$1
    
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/\${CLOUDFLARE_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer \${CLOUDFLARE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"AAAA\",\"name\":\"\${CLOUDFLARE_RECORD_NAME}\",\"content\":\"\${ipv6}\",\"ttl\":120,\"proxied\":false}" >/dev/null 2>&1
    
    return \$?
}

# 主函数
main() {
    log "INFO" "开始执行Cloudflare DDNS更新"
    
    # 获取当前IPv6地址
    local current_ipv6=\$(get_current_ipv6)
    if [[ -z "\$current_ipv6" ]]; then
        log "ERROR" "无法获取当前IPv6地址"
        exit 1
    fi
    log "INFO" "当前IPv6地址：\${current_ipv6}"
    
    # 获取Cloudflare记录
    local record=\$(get_cloudflare_record)
    local record_id=\$(echo "\$record" | grep -oP '(?<="id":")[^"]+' | head -1)
    local record_content=\$(echo "\$record" | grep -oP '(?<="content":")[^"]+' | head -1)
    
    # 比较IPv6地址是否变化
    if [[ "\$current_ipv6" == "\$record_content" ]]; then
        log "INFO" "IPv6地址未变化，无需更新"
        exit 0
    fi
    
    # 更新或创建记录
    if [[ -n "\$record_id" ]]; then
        log "INFO" "更新Cloudflare记录：\${CLOUDFLARE_RECORD_NAME} -> \${current_ipv6}"
        update_cloudflare_record "\$record_id" "\$current_ipv6"
        if [[ \$? -eq 0 ]]; then
            log "INFO" "Cloudflare记录更新成功"
            exit 0
        else
            log "ERROR" "Cloudflare记录更新失败"
            exit 1
        fi
    else
        log "INFO" "创建Cloudflare记录：\${CLOUDFLARE_RECORD_NAME} -> \${current_ipv6}"
        create_cloudflare_record "\$current_ipv6"
        if [[ \$? -eq 0 ]]; then
            log "INFO" "Cloudflare记录创建成功"
            exit 0
        else
            log "ERROR" "Cloudflare记录创建失败"
            exit 1
        fi
    fi
}

# 执行主函数
main
EOF
    
    chmod +x /opt/dnsha/cloudflare_ddns.sh
    
    # 创建systemd定时器
    cat > /etc/systemd/system/cloudflare_ddns.timer << 'EOF'
[Unit]
Description=Cloudflare DDNS Update Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
    
    cat > /etc/systemd/system/cloudflare_ddns.service << 'EOF'
[Unit]
Description=Cloudflare DDNS Update Service

[Service]
Type=oneshot
ExecStart=/opt/dnsha/cloudflare_ddns.sh

[Install]
WantedBy=multi-user.target
EOF
    
    # 清理旧的定时器（如果存在）
    systemctl stop dnsha_ddns.timer 2>/dev/null
    systemctl disable dnsha_ddns.timer 2>/dev/null
    rm -f /etc/systemd/system/dnsha_ddns.timer /etc/systemd/system/dnsha_ddns.service /opt/dnsha/update_ddns.sh 2>/dev/null
    
    # 启用新的定时器
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable cloudflare_ddns.timer >/dev/null 2>&1
    systemctl start cloudflare_ddns.timer >/dev/null 2>&1
    
    echo_success "Cloudflare DDNS自动更新脚本已创建，每小时执行一次"
}

# 主函数
main() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}DNSHA 一键安装脚本${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo -e "基于 SmartDNS + AdGuard Home 构建高可用DNS服务"
    echo -e "支持 VRRP/Haproxy/Consul 三种容灾模式"
    echo -e "自动检测当地运营商并配置最优DNS"
    echo -e "支持交互式设置固定IPv4/IPv6地址"
    echo -e "支持IPv6 DHCP自动获取地址"
    echo -e "支持Cloudflare DDNS域名绑定"
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
    
    # 如果没有通过命令行指定IP，进入交互模式
    if [[ -z "$IPV4_ADDR" && -z "$IPV6_ADDR" ]]; then
        interactive_ip_setup
    fi
    
    # 设置IPv4（如果提供了）
    if [[ -n "$IPV4_ADDR" && -n "$IPV4_GATEWAY" ]]; then
        set_ipv4 "$IPV4_ADDR" "$IPV4_GATEWAY" "$NET_INTERFACE"
    elif [[ -n "$IPV4_ADDR" || -n "$IPV4_GATEWAY" ]]; then
        echo_error "设置IPv4时必须同时提供IPv4地址和网关"
    fi
    
    # 设置IPv6
    if [[ -n "$IPV6_ADDR" && -n "$IPV6_GATEWAY" ]]; then
        set_ipv6 "$NET_INTERFACE" "$IPV6_ADDR" "$IPV6_GATEWAY" "static"
    elif [[ "$IPV6_MODE" == "dhcp" || -z "$IPV6_ADDR" ]]; then
        set_ipv6 "$NET_INTERFACE" "" "" "dhcp"
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
    echo -e "\n  # 手动更新Cloudflare DDNS"
    echo -e "  /opt/dnsha/cloudflare_ddns.sh"
    echo -e "\n  # 查看DDNS更新日志"
    echo -e "  tail -f /var/log/cloudflare_ddns.log"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"