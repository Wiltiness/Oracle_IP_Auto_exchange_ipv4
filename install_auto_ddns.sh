#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

echo -e "${GREEN}====================================================${PLAIN}"
echo -e "${GREEN}     OCI 自动换 IP + Cloudflare 专属 DDNS 安装工具     ${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[-] 请使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 2. 解析命令行传参
CF_TOKEN=""
CF_ZONE_ID=""
BASE_DOMAIN=""
CF_PROXIED=""
INTERVAL=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --token) CF_TOKEN="$2"; shift ;;
        --zone) CF_ZONE_ID="$2"; shift ;;
        --domain) BASE_DOMAIN="$2"; shift ;;
        --proxied) CF_PROXIED="$2"; shift ;;
        --interval) INTERVAL="$2"; shift ;;
        -h|--help)
            echo "用法示例 (支持传参静默安装，无需传租户名，全部自动获知):"
            echo "  $0 --token <CF_TOKEN> --zone <ZONE_ID> --domain example.com [--proxied false] [--interval 12h]"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
    shift
done

# 3. 检查并安装 OCI CLI / SDK 环境
echo -e "\n${YELLOW}[1/4] 检查 OCI 运行环境...${PLAIN}"
OCI_PYTHON="/root/lib/oracle-cli/bin/python3"
if [ ! -f "$OCI_PYTHON" ]; then
    echo -e "[*] 未检测到 OCI SDK 环境，正在静默安装..."
    bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
    exec -l $SHELL 2>/dev/null || true
fi
if [ ! -f "$OCI_PYTHON" ]; then
    OCI_PYTHON=$(head -n 1 $(which oci 2>/dev/null) 2>/dev/null | sed 's/#!//')
fi
if [ ! -f "$OCI_PYTHON" ]; then
    echo -e "${RED}[-] OCI Python 环境安装失败！${PLAIN}"
    exit 1
fi
echo -e "${GREEN}[+] OCI SDK 环境就绪: $OCI_PYTHON${PLAIN}"

# 4. 自动分发核心 Python 脚本到 /usr/local/bin
TARGET_PY="/usr/local/bin/oci_change_ip_ddns.py"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/oci_change_ip_ddns.py" ]; then
    cp "$SCRIPT_DIR/oci_change_ip_ddns.py" "$TARGET_PY"
else
    echo -e "[*] 正在从 GitHub 下载最新核心业务脚本..."
    curl -sSL https://raw.githubusercontent.com/Wiltiness/Oracle_IP_Auto_exchange_ipv4/master/oci_change_ip_ddns.py -o "$TARGET_PY"
fi
chmod +x "$TARGET_PY"
echo -e "${GREEN}[+] 核心业务脚本已部署: $TARGET_PY${PLAIN}"

# 5. 自动探测实例信息与权限
echo -e "\n${YELLOW}[2/4] 自动探测服务器地理元数据与租户名...${PLAIN}"
INST_JSON=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/)
INST_ID=$(echo "$INST_JSON" | grep -o '"id": "ocid1\.instance\.[^"]*"' | head -n 1 | awk -F'"' '{print $4}')
TENANCY_OCID=$(echo "$INST_JSON" | grep -o '"tenantId": "[^"]*"' | head -n 1 | awk -F'"' '{print $4}')
REGION_KEY=$(echo "$INST_JSON" | grep -o '"regionKey": "[^"]*"' | head -n 1 | awk -F'"' '{print $4}' | tr '[:upper:]' '[:lower:]')
OCID_4=$(echo "$INST_ID" | tail -c 5 | head -c 4)

# 权限探测
VNIC_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/ | grep -o '"vnicId": "[^"]*"' | head -n 1 | awk -F'"' '{print $4}')
TEST_AUTH=$(/root/bin/oci network vnic get --vnic-id "$VNIC_ID" --auth instance_principal 2>&1 || true)
if echo "$TEST_AUTH" | grep -q "NotAuthorizedOrNotFound"; then
    echo -e "${RED}[-] 错误：实例主体（Instance Principal）权限未就绪！${PLAIN}"
    echo -e "${YELLOW}请确保 OCI 控制台已将该实例 OCID 加入动态组并绑定策略！${PLAIN}"
    exit 1
fi
echo -e "${GREEN}[+] OCI 实例主体鉴权验证通过！${PLAIN}"

# 自动读取真实租户名
echo -e "[*] 正在通过 API 自动读取真实租户名..."
TENANT_NAME=$(/root/bin/oci iam tenancy get --tenancy-id "$TENANCY_OCID" --auth instance_principal --query "data.name" --raw-output 2>/dev/null || echo "tenant")
echo -e "[+] 自动识别真实租户名: ${GREEN}${TENANT_NAME}${PLAIN}"

# 探测国家码
COUNTRY_CODE=$(curl -s --max-time 5 http://ip-api.com/json/ | grep -o '"countryCode":"[^"]*"' | awk -F'"' '{print $4}' | tr '[:upper:]' '[:lower:]' || echo "xx")
echo -e "[+] 自动探测出口国家码: ${GREEN}${COUNTRY_CODE}${PLAIN}"

# 6. 交互式录入（若未通过命令行参数指定）
echo -e "\n${YELLOW}[3/4] 配置 Cloudflare 与基础域名（仅需 3 项）：${PLAIN}"
if [ -z "$CF_TOKEN" ]; then
    read -p "1. 请输入 Cloudflare API Token (需具备 DNS Write 权限): " CF_TOKEN
fi
if [ -z "$CF_ZONE_ID" ]; then
    read -p "2. 请输入 Cloudflare Zone ID: " CF_ZONE_ID
fi
if [ -z "$BASE_DOMAIN" ]; then
    read -p "3. 请输入根域名/基础域名 (例如 example.com 或 node.example.com): " BASE_DOMAIN
fi
if [ -z "$CF_PROXIED" ]; then
    read -p "4. 是否开启小黄云代理 (true/false) [默认: false]: " CF_PROXIED
    CF_PROXIED=${CF_PROXIED:-false}
fi
if [ -z "$INTERVAL" ]; then
    read -p "5. 自动换 IP 周期 (如 6h / 12h / 1d) [默认: 12h]: " INTERVAL
    INTERVAL=${INTERVAL:-12h}
fi

# 预览拼接效果
SAMPLE_PREFIX="${OCID_4}-${REGION_KEY}-${COUNTRY_CODE}-${TENANT_NAME}"
echo -e "\n${BLUE}[*] 域名规则预览：${PLAIN}"
echo -e "    实例后4位: ${GREEN}${OCID_4}${PLAIN} | 地区码: ${GREEN}${REGION_KEY}${PLAIN} | 国家码: ${GREEN}${COUNTRY_CODE}${PLAIN} | 租户名: ${GREEN}${TENANT_NAME}${PLAIN}"
echo -e "    最终自动更新的完整专属 DDNS 域名: ${YELLOW}${SAMPLE_PREFIX}.${BASE_DOMAIN}${PLAIN}"

# 写入配置文件
mkdir -p /etc/oci_ddns
cat << EOF > /etc/oci_ddns/config.json
{
  "cf_api_token": "${CF_TOKEN}",
  "cf_zone_id": "${CF_ZONE_ID}",
  "base_domain": "${BASE_DOMAIN}",
  "tenant_name": "${TENANT_NAME}",
  "cf_proxied": ${CF_PROXIED}
}
EOF
chmod 600 /etc/oci_ddns/config.json

# 7. 配置 Systemd 定时服务
echo -e "\n${YELLOW}[4/4] 注册系统服务与定时调度器...${PLAIN}"
cat << EOF > /etc/systemd/system/oci-ddns.service
[Unit]
Description=OCI Auto Change IP and Update Cloudflare DDNS
After=network.target

[Service]
Type=oneshot
ExecStart=${OCI_PYTHON} ${TARGET_PY}
StandardOutput=append:/var/log/oci_ddns.log
StandardError=append:/var/log/oci_ddns.log
EOF

cat << EOF > /etc/systemd/system/oci-ddns.timer
[Unit]
Description=Run OCI DDNS Task Periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now oci-ddns.timer

echo -e "\n${GREEN}====================================================${PLAIN}"
echo -e "${GREEN}             恭喜！所有配置安装完成！             ${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"
echo -e "执行周期：每 ${YELLOW}${INTERVAL}${PLAIN} 自动轮换一次 IP 并更新 DNS"
echo -e "日志路径：${YELLOW}/var/log/oci_ddns.log${PLAIN}"
echo -e "\n立即手动触发测试命令："
echo -e "  ${GREEN}systemctl start oci-ddns.service && tail -f /var/log/oci_ddns.log${PLAIN}"