#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Cloudflare DDNS 全自动部署 (智能版) ${NC}"
echo -e "${GREEN}======================================${NC}"

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 检查并安装依赖 (curl 和 jq)
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}检测到缺少依赖 (curl 或 jq)，正在尝试安装...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -y && apt-get install curl jq -y
    elif command -v yum &> /dev/null; then
        yum install curl jq -y
    else
        echo -e "${RED}无法自动安装依赖，请手动安装 curl 和 jq 后重试！${NC}"
        exit 1
    fi
fi

echo -e "\n${RED}注意：运行前，请确保你已经在 CF 网页上手动添加了这条 A 记录！(随便填个IP即可)${NC}\n"

# 收集用户输入 (不再需要 Record ID)
read -p "1. 请输入 API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " CF_ZONE_ID
read -p "3. 请输入你的解析域名 (例如 ip4.yw358133117.top): " DOMAIN
read -p "4. 是否开启 Cloudflare 代理(小黄云)? (输入 y 开启，其他任意键为仅DNS解析): " PROXIED_INPUT

if [ "$PROXIED_INPUT" == "y" ] || [ "$PROXIED_INPUT" == "Y" ]; then
    PROXIED="true"
else
    PROXIED="false"
fi

if [ -z "$CF_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误：Token、Zone ID 和域名都不能为空！${NC}"
    exit 1
fi

# ================= 自动获取 Record ID =================
echo -e "\n${YELLOW}正在通过 API 自动查询 $DOMAIN 的 Record ID...${NC}"

API_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json")

# 检查 API 是否报错
if echo "$API_RESPONSE" | jq -e '.success' > /dev/null 2>&1; then
    # API调用成功，尝试提取ID
    CF_RECORD_ID=$(echo "$API_RESPONSE" | jq -r '.result[0].id')
    
    if [ -z "$CF_RECORD_ID" ] || [ "$CF_RECORD_ID" == "null" ]; then
        echo -e "${RED}查询失败：找不到域名 $DOMAIN 的记录！${NC}"
        echo -e "${RED}请务必先去 Cloudflare 网页上手动添加这条 A 记录！${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 成功获取到 Record ID: $CF_RECORD_ID${NC}"
else
    ERROR_MSG=$(echo "$API_RESPONSE" | jq -r '.errors[0].message')
    echo -e "${RED}API 调用失败！错误信息: $ERROR_MSG${NC}"
    echo -e "${RED}请检查你的 API Token 和 Zone ID 是否正确。${NC}"
    exit 1
fi
# =======================================================

echo -e "${YELLOW}正在生成核心守护脚本...${NC}"

# 生成核心 DDNS 脚本
cat << 'EOF' > /root/ddns_daemon.sh
#!/bin/bash
CF_TOKEN="__TOKEN__"
CF_ZONE_ID="__ZONE_ID__"
CF_RECORD_ID="__RECORD_ID__"
DOMAIN="__DOMAIN__"
PROXIED="__PROXIED__"
IP_FILE="/root/.current_ip.txt"

NEW_IP=$(curl -s --connect-timeout 5 https://api.ip.sb/ip)

if [ -z "$NEW_IP" ]; then
    exit 1
fi

OLD_IP=$(cat $IP_FILE 2>/dev/null)

if [ "$NEW_IP" = "$OLD_IP" ]; then
    exit 0
fi

RESPONSE=$(curl -s --connect-timeout 5 -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$NEW_IP\",\"ttl\":1,\"proxied\":$PROXIED}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 成功: $OLD_IP -> $NEW_IP"
    echo "$NEW_IP" > $IP_FILE
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 失败: API返回错误"
fi
EOF

# 注入变量
sed -i "s|__TOKEN__|${CF_TOKEN}|g" /root/ddns_daemon.sh
sed -i "s|__ZONE_ID__|${CF_ZONE_ID}|g" /root/ddns_daemon.sh
sed -i "s|__RECORD_ID__|${CF_RECORD_ID}|g" /root/ddns_daemon.sh
sed -i "s|__DOMAIN__|${DOMAIN}|g" /root/ddns_daemon.sh
sed -i "s|__PROXIED__|${PROXIED}|g" /root/ddns_daemon.sh

chmod +x /root/ddns_daemon.sh

echo -e "${YELLOW}正在设置定时任务...${NC}"
(crontab -l 2>/dev/null | grep -v "ddns_daemon"; echo "*/5 * * * * /bin/bash /root/ddns_daemon.sh >> /root/ddns.log 2>&1"; echo "0 3 * * * echo "" > /root/ddns.log") | crontab -

echo -e "${YELLOW}正在执行首次同步...${NC}"
/bin/bash /root/ddns_daemon.sh

if [ $? -eq 0 ]; then
    CURRENT_IP=$(cat /root/.current_ip.txt 2>/dev/null)
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}       🎉 部署大成功！一切自动搞定！     ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "当前解析IP: ${GREEN}${CURRENT_IP}${NC}"
    echo -e "解析域名:   ${GREEN}${DOMAIN}${NC}"
    echo -e "自动获取ID: ${GREEN}${CF_RECORD_ID}${NC}"
    echo -e "\n后续说明："
    echo -e "1. 脚本已后台静默运行，每 5 分钟自动检查并换IP。"
    echo -e "2. 查看日志输入: ${YELLOW}cat /root/ddns.log${NC}"
else
    echo -e "\n${RED}首次运行失败，请检查上方报错信息。${NC}"
fi
