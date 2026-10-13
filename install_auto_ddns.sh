#!/bin/bash
set - e

GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[1;33m'
PLAIN = '\033[0m'

echo - e
"${GREEN}====================================================${PLAIN}"
echo - e
"${GREEN}       OCI 自动更换公网 IP + Cloudflare DDNS 安装工具        ${PLAIN}"
echo - e
"${GREEN}====================================================${PLAIN}"

# 1. 检查 root 权限
if ["$EUID" - ne 0]; then
echo - e
"${RED}[-] 请使用 root 用户运行此脚本！${PLAIN}"
exit
1
fi

# 2. 检查并安装 OCI CLI 运行环境
echo - e
"\n${YELLOW}[1/5] 检查 OCI Python 环境...${PLAIN}"
OCI_PYTHON = "/root/lib/oracle-cli/bin/python3"

if [ ! -f "$OCI_PYTHON"]; then
echo - e
"[*] 未检测到 OCI SDK 环境，正在静默安装..."
bash - c
"$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" - - --accept - all - defaults
exec - l $SHELL
2 > / dev / null | | true
fi

if [ ! -f "$OCI_PYTHON"]; then
OCI_PYTHON =$(head - n 1 $(which oci 2 > / dev / null)
2 > / dev / null | sed
's/#!//')
fi

if [ ! -f "$OCI_PYTHON"]; then
echo - e
"${RED}[-] OCI Python 环境安装失败，请手动排查！${PLAIN}"
exit
1
fi
echo - e
"${GREEN}[+] OCI 环境就绪: $OCI_PYTHON${PLAIN}"

# 3. 自动探测实例区域与权限测试
echo - e
"\n${YELLOW}[2/5] 嗅探服务器机房与 IAM 权限探测...${PLAIN}"
REGION =$(curl - s - H
          "Authorization: Bearer Oracle" http: // 169.254.169.254 / opc / v2 / instance / | grep -o '"canonicalRegionName": "[^"]*"' | awk -F'"' '{print $4}')
echo - e
"[*] 当前服务器区域: ${GREEN}${REGION}${PLAIN}"

VNIC_ID =$(curl - s - H
           "Authorization: Bearer Oracle" http: // 169.254.169.254 / opc / v2 / vnics / | grep -o '"vnicId": "[^"]*"' | head -n 1 | awk -F'"' '{print $4}')
TEST_AUTH =$(/ root / bin / oci network vnic get --vnic-id "$VNIC_ID" --auth instance_principal 2 > & 1 | | true)

if echo "$TEST_AUTH" | grep -q "NotAuthorizedOrNotFound"; then
echo - e
"${RED}[-] 警告：实例主体（Instance Principal）权限未就绪！${PLAIN}"
echo - e
"${YELLOW}请确保已在 OCI 控制台配置以下两项：${PLAIN}"
echo - e
"  1. 动态组包含当前机器 OCID"
echo - e
"  2. 策略包含: Allow dynamic-group 'Default'/'你的组名' to manage virtual-network-family in tenancy"
echo - e
"请配置完毕后再运行本安装脚本！"
exit
1
fi
echo - e
"${GREEN}[+] OCI 实例主体（Instance Principal）权限验证通过！${PLAIN}"

# 4. 交互式录入 Cloudflare 配置
echo - e
"\n${YELLOW}[3/5] 请输入 Cloudflare DDNS 配置信息：${PLAIN}"
read - p
"请输入 Cloudflare API Token (需具备 DNS Write 权限): "
CF_TOKEN
read - p
"请输入 Zone ID (区域标识符): "
CF_ZONE_ID
read - p
"请输入 DNS Record ID (需要更新的解析记录 ID): "
CF_RECORD_ID
read - p
"请输入完整域名 (例如 sub.example.com): "
CF_DOMAIN
read - p
"是否开启 Cloudflare 代理/CDN (true/false, 默认为 false): "
CF_PROXIED
CF_PROXIED =${CF_PROXIED: -false}

mkdir - p / etc / oci_ddns
cat << EOF > / etc / oci_ddns / config.json
{
    "cf_api_token": "${CF_TOKEN}",
    "cf_zone_id": "${CF_ZONE_ID}",
    "cf_record_id": "${CF_RECORD_ID}",
    "cf_domain": "${CF_DOMAIN}",
    "cf_proxied": ${CF_PROXIED}
}
EOF
chmod
600 / etc / oci_ddns / config.json
echo - e
"${GREEN}[+] 配置已加密保存到 /etc/oci_ddns/config.json${PLAIN}"

# 5. 写入主任务脚本
echo - e
"\n${YELLOW}[4/5] 部署核心任务脚本...${PLAIN}"
cat << 'EOF' > / usr / local / bin / oci_change_ip_ddns.py
import os
import sys
import time
import json
import urllib.request
import urllib.error
import oci

CONFIG_FILE = "/etc/oci_ddns/config.json"
IMDS_HEADERS = {"Authorization": "Bearer Oracle"}


def log(msg):
    now = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{now}] {msg}", flush=True)


def get_meta(path):
    req = urllib.request.Request(f"http://169.254.169.254/opc/v2/{path}", headers=IMDS_HEADERS)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode('utf-8'))


def load_config():
    if not os.path.exists(CONFIG_FILE):
        log(f"[-] 配置文件不存在: {CONFIG_FILE}")
        sys.exit(1)
    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def update_cloudflare_dns(cf_token, zone_id, record_id, domain_name, new_ip, proxied=False):
    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}"
    payload = {
        "name": domain_name,
        "ttl": 1,
        "type": "A",
        "comment": f"Auto-updated by OCI script at {time.strftime('%Y-%m-%d %H:%M:%S')}",
        "content": new_ip,
        "proxied": proxied
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode('utf-8'),
        headers={
            "Authorization": f"Bearer {cf_token}",
            "Content-Type": "application/json"
        },
        method="PUT"
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            res_data = json.loads(resp.read().decode('utf-8'))
            if res_data.get("success"):
                log(f"[+] Cloudflare DNS 同步成功: {domain_name} -> {new_ip} (Proxied: {proxied})")
                return True
            else:
                log(f"[-] Cloudflare 返回错误: {res_data.get('errors')}")
                return False
    except Exception as e:
        log(f"[-] 请求 Cloudflare API 失败: {e}")
        return False


def verify_ip_api():
    try:
        req = urllib.request.Request("http://ip-api.com/json/", headers={"User-Agent": "curl/8.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            info = json.loads(resp.read().decode('utf-8'))
            if info.get("status") == "success":
                log(f"[*] IP-API 验证成功: IP={info.get('query')} | 地区={info.get('country')} - {info.get('city')} | ISP={info.get('isp')}")
    except Exception as e:
        log(f"[*] IP-API 提示: {e}")


def main():
    config = load_config()

    log("[*] 正在嗅探服务器所在的 OCI 全球区域...")
    inst_meta = get_meta("instance/")
    compartment_id = inst_meta["compartmentId"]
    region = inst_meta.get("canonicalRegionName") or inst_meta.get("region")
    realm_domain = inst_meta.get("regionInfo", {}).get("realmDomainComponent", "oraclecloud.com")

    endpoint = f"https://iaas.{region}.ds.oci.{realm_domain}"
    log(f"[*] 匹配区域: {region} | 双栈接入端点: {endpoint}")

    vnic_meta = get_meta("vnics/")
    vnic_id = vnic_meta[0]["vnicId"]

    log("[*] 正在初始化 OCI 实例主体鉴权...")
    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    client = oci.core.VirtualNetworkClient(config={}, signer=signer, service_endpoint=endpoint)

    private_ips = client.list_private_ips(vnic_id=vnic_id).data
    primary_ip_id = private_ips[0].id

    pub_ip_details = oci.core.models.GetPublicIpByPrivateIpIdDetails(private_ip_id=primary_ip_id)
    try:
        public_ip = client.get_public_ip_by_private_ip_id(pub_ip_details).data
        old_public_ip_id = public_ip.id
        log(f"[*] 找到旧公网 IP: {public_ip.ip_address} (ID: {old_public_ip_id})")
    except Exception:
        old_public_ip_id = None

    if old_public_ip_id:
        log("[*] 正在注销释放旧公网 IP...")
        client.delete_public_ip(public_ip_id=old_public_ip_id)
        log("[*] 等待 8 秒让私网 IP 状态彻底解锁...")
        time.sleep(8)

    log("[*] 正在申请分配全新临时公网 IP...")
    create_details = oci.core.models.CreatePublicIpDetails(
        compartment_id=compartment_id,
        lifetime="EPHEMERAL",
        private_ip_id=primary_ip_id
    )
    new_ip_resp = client.create_public_ip(create_details)
    new_ip = new_ip_resp.data.ip_address
    log(f"[+] OCI 换 IP 成功！新分配的公网 IP: {new_ip}")

    with open("/root/current_ip.txt", "w") as f:
        f.write(new_ip + "\n")

    time.sleep(3)
    log("[*] 正在触发 Cloudflare DDNS 覆盖记录...")
    update_cloudflare_dns(
        cf_token=config["cf_api_token"],
        zone_id=config["cf_zone_id"],
        record_id=config["cf_record_id"],
        domain_name=config["cf_domain"],
        new_ip=new_ip,
        proxied=config.get("cf_proxied", False)
    )

    verify_ip_api()
    log("[+] 整体任务圆满完成！")


if __name__ == "__main__":
    main()
EOF
chmod + x / usr / local / bin / oci_change_ip_ddns.py

# 6. 配置 Systemd 定时器
echo - e
"\n${YELLOW}[5/5] 配置定时执行周期...${PLAIN}"
echo - e
"支持格式示例："
echo - e
"  - 每 30 分钟一次: ${GREEN}30m${PLAIN}"
echo - e
"  - 每 6 小时一次:  ${GREEN}6h${PLAIN}"
echo - e
"  - 每 12 小时一次: ${GREEN}12h${PLAIN}"
echo - e
"  - 每天一次:       ${GREEN}1d${PLAIN}"
read - p
"请输入定时执行周期 (默认 12h): "
INTERVAL
INTERVAL =${INTERVAL: -12h}

# 编写 systemd service
cat << EOF > / etc / systemd / system / oci - ddns.service
[Unit]
Description = OCI
Auto
Change
IP and Update
Cloudflare
DDNS
After = network.target

[Service]
Type = oneshot
ExecStart =${OCI_PYTHON} / usr / local / bin / oci_change_ip_ddns.py
StandardOutput = append: / var / log / oci_ddns.log
StandardError = append: / var / log / oci_ddns.log
EOF

# 编写 systemd timer
cat << EOF > / etc / systemd / system / oci - ddns.timer
[Unit]
Description = Run
OCI
DDNS
Task
Periodically

[Timer]
OnBootSec = 2
min
OnUnitActiveSec =${INTERVAL}
Persistent = true

[Install]
WantedBy = timers.target
EOF

systemctl
daemon - reload
systemctl
enable - -now
oci - ddns.timer

echo - e
"\n${GREEN}====================================================${PLAIN}"
echo - e
"${GREEN}             恭喜！所有配置安装完成！             ${PLAIN}"
echo - e
"${GREEN}====================================================${PLAIN}"
echo - e
"当前设置执行周期：每 ${YELLOW}${INTERVAL}${PLAIN} 自动执行一次"
echo - e
"日志文件路径：    ${YELLOW}/var/log/oci_ddns.log${PLAIN}"
echo - e
"\n你可以使用以下常用命令进行管理："
echo - e
"  1. 查看定时器状态:   ${GREEN}systemctl status oci-ddns.timer${PLAIN}"
echo - e
"  2. 手动立即触发一次: ${GREEN}systemctl start oci-ddns.service${PLAIN}"
echo - e
"  3. 查看执行实时日志: ${GREEN}tail -f /var/log/oci_ddns.log${PLAIN}"