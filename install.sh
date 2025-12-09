#!/bin/bash
# DNSHA 一键安装脚本
# 支持 curl xxx | bash 方式一键部署
# 自动检测当地运营商并配置最优DNS
# Author: DNSHA Team
# License: MIT
# Version: 1.0.0

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
    echo -e "${BLUE}=====================================${NC}\n"
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo_error "请以root用户运行此脚本"
    fi
    
    # 检测系统
    detect_system
    
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
    echo -e "\n${YELLOW}接下来可以执行：${NC}"
    echo -e "  # 一键部署主备节点"
    echo -e "  /opt/dnsha/deploy_dns.sh --help"
    echo -e "\n  # 查看健康检查"
    echo -e "  /opt/dnsha/health_check.sh --help"
    echo -e "${BLUE}=====================================${NC}"
}

# 脚本入口
main "$@"