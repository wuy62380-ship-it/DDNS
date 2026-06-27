#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}  Cloudflare 动态IP自动更新(DDNS)部署  ${NC}"
echo -e "${GREEN}======================================${NC}"

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# 检查并安装 curl
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}检测到未安装 curl，正在尝试安装...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -y && apt-get install curl -y
    elif command -v yum &> /dev/null; then
        yum install curl -y
    else
        echo -e "${RED}无法自动安装 curl，请手动安装后重试！${NC}"
        exit 1
    fi
fi

# 收集用户输入
echo -e "\n${YELLOW}请按照提示输入 Cloudflare 的配置信息 (没有空格直接回车即可)：${NC}"
read -p "1. 请输入 API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " CF_ZONE_ID
read -p "3. 请输入 Record ID: " CF_RECORD_ID
read -p "4. 请输入你的解析域名 (例如 ddns.example.com): " DOMAIN
read -p "5. 是否开启 Cloudflare 代理(小黄云)? (输入 y 开启，其他任意键为仅DNS解析): " PROXIED_INPUT

if [ "$PROXIED_INPUT" == "y" ] || [ "$PROXIED_INPUT" == "Y" ]; then
    PROXIED="true"
else
    PROXIED="false"
fi

# 验证输入是否为空
if [ -z "$CF_TOKEN" ] || [ -z "$CF_ZONE_ID" ] || [ -z "$CF_RECORD_ID" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误：API Token、Zone ID、Record ID 和域名都不能为空！${NC}"
    exit 1
fi

echo -e "\n${YELLOW}正在生成核心脚本...${NC}"

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

# 使用 sed 替换脚本中的占位符
sed -i "s|__TOKEN__|${CF_TOKEN}|g" /root/ddns_daemon.sh
sed -i "s|__ZONE_ID__|${CF_ZONE_ID}|g" /root/ddns_daemon.sh
sed -i "s|__RECORD_ID__|${CF_RECORD_ID}|g" /root/ddns_daemon.sh
sed -i "s|__DOMAIN__|${DOMAIN}|g" /root/ddns_daemon.sh
sed -i "s|__PROXIED__|${PROXIED}|g" /root/ddns_daemon.sh

chmod +x /root/ddns_daemon.sh

echo -e "${YELLOW}正在设置定时任务...${NC}"

# 移除旧的任务（如果有），并添加新任务（每5分钟执行一次 + 每天凌晨3点清空日志）
(crontab -l 2>/dev/null | grep -v "ddns_daemon"; echo "*/5 * * * * /bin/bash /root/ddns_daemon.sh >> /root/ddns.log 2>&1"; echo "0 3 * * * echo "" > /root/ddns.log") | crontab -

echo -e "${YELLOW}正在执行首次检测与同步...${NC}"
# 首次执行，写入当前IP并验证API是否正确
/bin/bash /root/ddns_daemon.sh

if [ $? -eq 0 ]; then
    CURRENT_IP=$(cat /root/.current_ip.txt 2>/dev/null)
    echo -e "\n${GREEN}======================================${NC}"
    echo -e "${GREEN}       🎉 部署成功！一切运行正常！     ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo -e "当前解析IP: ${GREEN}${CURRENT_IP}${NC}"
    echo -e "解析域名:   ${GREEN}${DOMAIN}${NC}"
    echo -e "代理状态:   ${GREEN}$(if [ "$PROXIED" == "true" ]; then echo '已开启(小黄云)'; else echo '仅DNS(灰云)'; fi)${NC}"
    echo -e "\n后续说明："
    echo -e "1. 脚本已加入后台定时任务，每 5 分钟自动检查一次。"
    echo -e "2. 换IP后最多等待 5 分钟，Cloudflare 即会自动切换。"
    echo -e "3. 查看运行日志请输入: ${YELLOW}cat /root/ddns.log${NC}"
    echo -e "4. 彻底卸载请输入: ${YELLOW}crontab -l | grep -v ddns_daemon | crontab - && rm -f /root/ddns_daemon.sh /root/ddns.log /root/.current_ip.txt${NC}"
else
    echo -e "\n${RED}======================================${NC}"
    echo -e "${RED}       ❌ 首次运行失败，请检查配置！     ${NC}"
    echo -e "${RED}======================================${NC}"
    echo -e "常见失败原因："
    echo -e "1. API Token 错误或权限不够（需要 Edit zone DNS 权限）。"
    echo -e "2. Zone ID 或 Record ID 填错了。"
    echo -e "3. 服务器当前网络无法连接到 Cloudflare。"
    echo -e "\n你可以手动运行 ${YELLOW}/bin/bash /root/ddns_daemon.sh${NC} 来查看具体报错信息。"
fi
