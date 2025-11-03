#!/bin/sh

# 网络认证配置
log="captive.log"

# Portal服务器地址
portalServer="http://10.101.2.194:6060"

# 学号（请修改为你的学号）
userid=250408****
# 密码（请修改为你的密码）
password="Myhtu****"
# 运营商后缀，可选值: @htu, @yd, @lt, @dx, @htu.edu.cn
operatorSuffix="@htu"

# 设备信息（固定值和动态获取）
wanInterface="phy0-sta0"  # WiFi接口名称（phy0-sta0表示连接到WiFi的客户端接口）
portalURL=""
macAddress=""  # MAC地址（动态获取）
hostname=""  # 主机名（动态获取）
wanIP=""  # IP地址（需动态获取，因为DHCP会变化）

# 从Portal URL中提取的参数
wlanacname=""
wlanacIp=""
vlan=""
portalpageid=""

touch ${log}
timemark=$(date +"%Y年%m月%d日 %H:%M:%S")

# URL编码函数（简单版本）
urlencode() {
    echo "$1" | sed 's/@/%40/g; s/:/%3A/g; s/ /%20/g'
}

# 从URL中提取参数值
getUrlParam() {
    local url="$1"
    local param="$2"
    echo "$url" | sed -n "s/.*[?&]${param}=\([^&]*\).*/\1/p" | sed 's/%40/@/g'
}

# 获取设备信息（动态获取IP、MAC和主机名）
function GetDeviceInfo {
    echo "开始获取设备信息..."
    echo "尝试从接口 ${wanInterface} 获取IP..."
    
    # 获取WAN口IP（因为DHCP会动态分配）
    if command -v ip &> /dev/null; then
        wanIP=$(ip addr show ${wanInterface} 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
        if [ -n "${wanIP}" ]; then
            echo "从 ${wanInterface} 获取到IP: ${wanIP}"
        fi
    fi
    
    # 如果没有获取到IP，尝试从默认路由获取（可能是有其他接口）
    if [ -z "${wanIP}" ]; then
        echo "警告: 无法从 ${wanInterface} 获取IP，尝试从默认路由获取..."
        wanIP=$(ip route get 8.8.8.8 2>/dev/null | grep -o 'src [0-9.]*' | awk '{print $2}')
        if [ -n "${wanIP}" ]; then
            echo "从默认路由获取到IP: ${wanIP}"
        fi
    fi
    
    # 尝试从ifconfig获取
    if [ -z "${wanIP}" ]; then
        echo "尝试使用ifconfig从 ${wanInterface} 获取IP..."
        wanIP=$(ifconfig ${wanInterface} 2>/dev/null | grep "inet addr" | cut -d: -f2 | cut -d' ' -f1)
        if [ -n "${wanIP}" ]; then
            echo "从ifconfig获取到IP: ${wanIP}"
        fi
    fi
    
    # 尝试从所有接口获取（WiFi接口等）
    if [ -z "${wanIP}" ]; then
        echo "尝试从所有网络接口获取IP..."
        # 列出所有可能的接口（WiFi、以太网等）
        for iface in $(ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | cut -d: -f1 | grep -v lo); do
            if [ "${iface}" != "${wanInterface}" ]; then
                tempIP=$(ip addr show ${iface} 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
                if [ -n "${tempIP}" ] && [ "${tempIP#127.}" != "${tempIP}" ]; then
                    continue  # 跳过127.x.x.x本地地址
                fi
                if [ -n "${tempIP}" ]; then
                    echo "从接口 ${iface} 获取到IP: ${tempIP}"
                    wanIP="${tempIP}"
                    wanInterface="${iface}"  # 更新接口名称
                    break
                fi
            fi
        done
    fi
    
    # 如果还是没有IP，尝试从WiFi接口（OpenWRT常见的WiFi接口名）
    if [ -z "${wanIP}" ]; then
        echo "尝试从WiFi接口获取IP..."
        for wifiIf in phy0-sta0 wlan0 wlan1 wlan0-1 wlan1-1 ath0 sta0; do
            if [ -n "$(ip link show ${wifiIf} 2>/dev/null)" ]; then
                tempIP=$(ip addr show ${wifiIf} 2>/dev/null | grep "inet " | head -1 | awk '{print $2}' | cut -d'/' -f1)
                if [ -n "${tempIP}" ]; then
                    echo "从WiFi接口 ${wifiIf} 获取到IP: ${tempIP}"
                    wanIP="${tempIP}"
                    wanInterface="${wifiIf}"
                    break
                fi
            fi
        done
    fi
    
    # 获取MAC地址（从确定的接口）
    if command -v ip &> /dev/null; then
        macAddress=$(ip link show ${wanInterface} 2>/dev/null | grep "ether" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    fi
    
    if [ -z "${macAddress}" ]; then
        macAddress=$(ifconfig ${wanInterface} 2>/dev/null | grep "HWaddr\|ether" | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
    fi
    
    # 获取主机名
    hostname=$(uci get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'OpenWrt')
    
    echo "========================================"
    echo "设备信息获取结果:"
    echo "  MAC地址: ${macAddress:-未获取}"
    echo "  IP地址: ${wanIP:-未获取}"
    echo "  主机名: ${hostname}"
    echo "  使用接口: ${wanInterface}"
    echo "========================================"
    
    if [ -z "${wanIP}" ]; then
        echo "警告: 无法获取IP地址，请检查网络连接和接口配置！"
    fi
    if [ -z "${macAddress}" ]; then
        echo "警告: 无法获取MAC地址！"
    fi
}

# 检查网络连接
function ConnectionCheck {
    # 使用baidu.com检测网络连接
    httpCode=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 -m 10 http://www.baidu.com)
    if [ "${httpCode}" = "200" ]; then
        connection="1"
    else
        connection="0"
    fi
}

# 获取Portal页面并解析参数
function GetPortalPage {
    # 尝试访问一个会被重定向到Portal的URL
    echo "尝试获取Portal页面..."
    redirectURL=$(curl -Ls -o /dev/null -w "%{url_effective}" --connect-timeout 5 -m 5 "http://www.gstatic.com/generate_204" 2>/dev/null)
    
    case "${redirectURL}" in
        http://10.101.2.194:6060/portal*)
            portalURL="${redirectURL}"
            echo "获取到Portal URL: ${portalURL}"
            
            # 从Portal URL中提取参数（优先使用Portal URL中的IP）
            portalIP=$(getUrlParam "${portalURL}" "wlanuserip")
            if [ -n "${portalIP}" ] && [ -z "${wanIP}" ]; then
                echo "从Portal URL提取到IP: ${portalIP}"
                wanIP="${portalIP}"
            fi
            
            wlanacname=$(getUrlParam "${portalURL}" "wlanacname")
            wlanacIp=$(getUrlParam "${portalURL}" "wlanacIp")
            vlan=$(getUrlParam "${portalURL}" "vlan")
            
            # 如果URL中没有这些参数，尝试访问Portal页面获取
            if [ -z "${wlanacname}" ] || [ -z "${wlanacIp}" ] || [ -z "${vlan}" ]; then
                echo "从Portal URL提取参数不完整，尝试访问Portal页面..."
                portalContent=$(curl -s -L "${portalURL}" \
                    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
                    -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' \
                    2>/dev/null)
                
                # 尝试从页面内容中提取参数（如果URL中没有）
                if [ -z "${wlanacname}" ]; then
                    wlanacname=$(echo "${portalContent}" | grep -o 'wlanacname[=:][^"& ]*' | cut -d'=' -f2 | cut -d'"' -f1 | head -1)
                fi
                if [ -z "${wlanacIp}" ]; then
                    wlanacIp=$(echo "${portalContent}" | grep -o 'wlanacIp[=:][^"& ]*' | cut -d'=' -f2 | cut -d'"' -f1 | head -1)
                fi
                if [ -z "${vlan}" ]; then
                    vlan=$(getUrlParam "${portalURL}" "vlan")
                fi
            fi
            
            # 如果仍然没有，使用默认值或从URL构造的参数
            if [ -z "${wlanacname}" ]; then
                wlanacname="HSD-BRAS-2"
            fi
            if [ -z "${wlanacIp}" ]; then
                wlanacIp="10.101.2.36"
            fi
            if [ -z "${vlan}" ]; then
                vlan=$(getUrlParam "${portalURL}" "vlan")
                if [ -z "${vlan}" ]; then
                    vlan="19953614"  # 使用默认值，实际应该从Portal获取
                fi
            fi
            
            portalpageid="81"  # 默认值，实际应该从Portal配置获取
            echo "解析的参数: wlanacname=${wlanacname}, wlanacIp=${wlanacIp}, vlan=${vlan}, portalpageid=${portalpageid}"
            return 0
            ;;
        *)
            # 如果无法自动获取，使用默认值构造
            portalURL="${portalServer}/portal.do?wlanuserip=${wanIP}&wlanacname=HSD-BRAS-2&mac=${macAddress}&vlan=19953614&hostname=${hostname}"
            wlanacname="HSD-BRAS-2"
            wlanacIp="10.101.2.36"
            vlan="19953614"
            portalpageid="81"
            echo "使用构造的Portal URL和默认参数: ${portalURL}"
            return 1
            ;;
    esac
}

# 生成UUID（简单版本，兼容BusyBox）
generateUUID() {
    # 方法1: 使用 /dev/urandom（如果可用）
    if [ -c /dev/urandom ]; then
        # 读取16字节并转换为hex，使用cut提取各部分
        hex=$(od -A n -t x1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \n')
        if [ -n "${hex}" ]; then
            part1=$(echo "${hex}" | cut -c1-8)
            part2=$(echo "${hex}" | cut -c9-12)
            part3=$(echo "${hex}" | cut -c13-16)
            part4=$(echo "${hex}" | cut -c17-20)
            part5=$(echo "${hex}" | cut -c21-32)
            if [ -n "${part1}" ] && [ -n "${part5}" ]; then
                echo "${part1}-${part2}-${part3}-${part4}-${part5}"
                return 0
            fi
        fi
    fi
    
    # 方法2: 使用时间戳和随机数组合（完全BusyBox兼容）
    timestamp=$(date +%s)
    # 生成多个随机数
    r1=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r2=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r3=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r4=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r5=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    r6=$(awk 'BEGIN{srand();printf("%04x",int(rand()*65535))}')
    
    # 构建UUID格式: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    # 将时间戳转换为8位hex
    ts_hex=$(printf "%08x" $((timestamp % 4294967296)))
    echo "${ts_hex}-${r1}-${r2}-${r3}-${r4}${r5}${r6}"
}

# 认证请求（模拟浏览器行为，使用quickauth.do）
function Auth {
    echo "步骤1: 准备认证参数..."
    
    # 检查IP地址是否已获取
    if [ -z "${wanIP}" ]; then
        echo "错误: IP地址为空，无法进行认证！"
        echo "请检查："
        echo "  1. WiFi是否已连接到 HTU_Student"
        echo "  2. WAN接口名称是否正确（当前: ${wanInterface}）"
        echo "  3. 网络接口是否已获取到DHCP分配的IP"
        authResult="认证失败：IP地址为空，无法发送认证请求"
        return 1
    fi
    
    # 检查MAC地址
    if [ -z "${macAddress}" ]; then
        echo "警告: MAC地址为空，可能影响认证"
    fi
    
    # 生成时间戳（毫秒）
    sec_timestamp=$(date +%s)
    if [ -n "${sec_timestamp}" ]; then
        timestamp="${sec_timestamp}000"
    else
        # 如果date命令失败，使用备用方法
        timestamp=$(awk 'BEGIN{srand();print int(rand()*10000000000000)}')
    fi
    
    # 生成UUID
    uuid=$(generateUUID)
    
    # URL编码参数
    encodedUserid=$(urlencode "${userid}${operatorSuffix}")
    encodedMac=$(urlencode "${macAddress}")
    encodedHostname=$(urlencode "${hostname}")
    
    # 构建quickauth.do URL（GET请求，所有参数在URL中）
    authUrl="${portalServer}/quickauth.do?userid=${encodedUserid}&passwd=${password}&wlanuserip=${wanIP}&wlanacname=${wlanacname}&wlanacIp=${wlanacIp}&ssid=&vlan=${vlan}&mac=${encodedMac}&version=0&portalpageid=${portalpageid}&timestamp=${timestamp}&uuid=${uuid}&portaltype=0&hostname=${encodedHostname}&bindCtrlId="
    
    echo "步骤2: 发送认证请求..."
    echo "使用的参数:"
    echo "  IP地址: ${wanIP}"
    echo "  MAC地址: ${macAddress}"
    echo "  主机名: ${hostname}"
    echo "  AC名称: ${wlanacname}"
    echo "  AC IP: ${wlanacIp}"
    echo "  VLAN: ${vlan}"
    echo "认证URL: ${authUrl}"
    
    # 发送GET请求（模拟浏览器）
    echo "发送HTTP请求..."
    
    # 先尝试正常请求获取响应
    responseBody=$(curl -s -L "${authUrl}" \
        -H 'Accept: application/json, text/javascript, */*; q=0.01' \
        -H 'Accept-Encoding: gzip, deflate' \
        -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6' \
        -H 'Connection: keep-alive' \
        -H "Host: 10.101.2.194:6060" \
        -H "Referer: ${portalURL:-${portalServer}/portal.do}" \
        -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
        -H 'X-Requested-With: XMLHttpRequest' \
        -H "Cookie: macAuth=${macAddress}" \
        --connect-timeout 10 \
        --max-time 30 \
        --compressed \
        -w "\nHTTP_CODE:%{http_code}" \
        2>/dev/null)
    
    # 提取HTTP状态码和响应体
    httpCode=$(echo "${responseBody}" | grep "HTTP_CODE:" | cut -d: -f2)
    responseBody=$(echo "${responseBody}" | grep -v "HTTP_CODE:")
    
    # 如果没有响应，尝试获取错误信息
    if [ -z "${responseBody}" ] || [ "${responseBody}" = "HTTP_CODE:" ]; then
        echo "警告: 未收到响应，尝试获取详细错误信息..."
        errorInfo=$(curl -s -L "${authUrl}" \
            -H 'Accept: application/json, text/javascript, */*; q=0.01' \
            -H "Referer: ${portalURL:-${portalServer}/portal.do}" \
            -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0' \
            --connect-timeout 10 \
            --max-time 30 \
            -w "\nHTTP_CODE:%{http_code}\nERROR:%{errormsg}" \
            2>&1)
        responseBody=$(echo "${errorInfo}" | grep -v "HTTP_CODE:" | grep -v "ERROR:")
        httpCode=$(echo "${errorInfo}" | grep "HTTP_CODE:" | cut -d: -f2)
        if [ -z "${responseBody}" ]; then
            responseBody="请求失败: $(echo "${errorInfo}" | grep "ERROR:" | cut -d: -f2-)"
        fi
    fi
    
    # 步骤3: 处理返回结果
    echo "HTTP状态码: ${httpCode:-未知}"
    echo "认证响应: ${responseBody:-无响应}"
    authResult="${responseBody:-无响应}"
    
    # 检查响应是否成功
    if echo "${responseBody}" | grep -qi '"result":"success"\|"code":"1"\|"code":1\|success\|成功'; then
        echo "步骤3: 认证成功"
        authResult="认证成功: ${responseBody}"
    elif echo "${responseBody}" | grep -qi '"code":"0"\|"code":0'; then
        # code="0"可能是待处理状态或其他含义，检查message字段
        message=$(echo "${responseBody}" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "${message}" ]; then
            echo "步骤3: 收到响应 code=0，消息: ${message}"
            authResult="认证响应(code=0): ${message}"
        else
            echo "步骤3: 收到响应 code=0，但无详细消息"
            authResult="认证响应(code=0，可能需要进一步处理): ${responseBody}"
        fi
    elif echo "${responseBody}" | grep -qi '"result":"fail"\|"code":"-1"\|"code":-1\|fail\|失败'; then
        echo "步骤3: 认证失败"
        authResult="认证失败: ${responseBody}"
    else
        echo "步骤3: 认证响应: ${responseBody}"
    fi
}

# 日志记录
function Logger {
    if [ "${connection}" = "1" ]; then
        if [ "${authResult}" = "网络已连接，无需认证" ]; then
            result="网络已连接，无需认证"
        else
            result="网络正常"
        fi
    else
        # 使用case语句进行模式匹配（ash兼容）
        case "${authResult}" in
            *"已经在线"*|*"已登录"*)
                result="当前设备已登录"
                ;;
            *'"code":"1"'*|*'"code":1'*)
                result="认证检查成功"
                ;;
            *'"code":"0"'*|*'"code":0'*)
                # 检查是否有message字段
                if echo "${authResult}" | grep -q '"message":'; then
                    msg=$(echo "${authResult}" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
                    if [ -n "${msg}" ] && [ "${msg}" != "null" ]; then
                        result="认证响应: ${msg}"
                    else
                        result="认证响应(code=0，无详细消息)"
                    fi
                else
                    result="认证响应(code=0，可能需要进一步处理)"
                fi
                ;;
            *'"code":"-1"'*|*'"code":-1'*)
                result="认证失败，服务器返回code=-1"
                ;;
            *'result":"success'*)
                result="认证成功"
                ;;
            *'用户数量上限'*|*'用户在线数'*)
                result="其他设备已登录"
                ;;
            *'欠费'*)
                result="账户已欠费"
                ;;
            *'密码'*|*'username'*)
                result="用户名或密码错误"
                ;;
            *'msg'*)
                # 提取错误消息（使用BusyBox兼容的方法）
                msg=$(echo "${authResult}" | grep '"msg":"' | cut -d'"' -f4)
                if [ -n "${msg}" ]; then
                    result="认证失败: ${msg}"
                else
                    result="认证失败"
                fi
                ;;
            *)
                if [ -z "${authResult}" ]; then
                    result="认证失败：网络无响应"
                else
                    result="认证失败，服务器返回: ${authResult}"
                fi
                ;;
        esac
    fi
    printf "--------------------------------\n操作时间: %s\n网络状态: %s\n响应详情: %s\n\n" "${timemark}" "${result}" "${authResult}" >>${log}
}

# 日志清理（每月1号清空）
function Clog {
    if [ "$(date +"%d")" = "01" ]; then
        printf "日志已经在%s刷新\n\n" "${timemark}" >${log}
    fi
}

# 主运行函数
function Run {
    # 初始化
    authResult=""
    
    # 首先检查网络连接状态
    echo "检查网络连接状态..."
    ConnectionCheck
    
    # 如果网络畅通，直接退出，无需执行登录操作
    if [ "${connection}" = "1" ]; then
        echo "网络连接正常，无需执行认证操作"
        authResult="网络已连接，无需认证"
        Logger
        Clog
        cat ${log}
        exit 0
    fi
    
    # 网络不通，继续执行认证流程
    echo "网络未连接，开始认证流程..."
    
    # 获取设备信息
    GetDeviceInfo
    
    # 检查Portal认证状态
    echo "检查Portal认证状态..."
    GetPortalPage
    
    # 执行认证操作
    echo "执行认证..."
    Auth
    
    Logger
    Clog
    cat ${log}
    exit 0
}

Run
