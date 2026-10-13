#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import os
import sys
import time
import urllib.error
import urllib.request
import oci

CONFIG_FILE = "/etc/oci_ddns/config.json"
IMDS_HEADERS = {"Authorization": "Bearer Oracle"}


def log(msg):
  now = time.strftime("%Y-%m-%d %H:%M:%S")
  print(f"[{now}] {msg}", flush=True)


def get_meta(path):
  req = urllib.request.Request(
      f"http://169.254.169.254/opc/v2/{path}", headers=IMDS_HEADERS
  )
  with urllib.request.urlopen(req, timeout=5) as resp:
    return json.loads(resp.read().decode("utf-8"))


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
      "ttl": 1,  # 1 为 Automatic
      "type": "A",
      "comment": f"Auto-updated by OCI script at {time.strftime('%Y-%m-%d %H:%M:%S')}",
      "content": new_ip,
      "proxied": proxied,
  }

  req = urllib.request.Request(
      url,
      data=json.dumps(payload).encode("utf-8"),
      headers={
          "Authorization": f"Bearer {cf_token}",
          "Content-Type": "application/json",
      },
      method="PUT",
  )

  try:
    with urllib.request.urlopen(req, timeout=10) as resp:
      res_data = json.loads(resp.read().decode("utf-8"))
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
  """调用 ip-api.com 验证新 IP 出口及其地理信息"""
  try:
    req = urllib.request.Request("http://ip-api.com/json/", headers={"User-Agent": "curl/8.0"})
    with urllib.request.urlopen(req, timeout=8) as resp:
      info = json.loads(resp.read().decode("utf-8"))
      if info.get("status") == "success":
        log(f"[*] IP-API 验证成功: IP={info.get('query')} | 地区={info.get('country')} - {info.get('city')} | ISP={info.get('isp')}")
  except Exception as e:
    log(f"[*] IP-API 探针提示（非致命）: {e}")


def main():
  config = load_config()

  # 1. 自动嗅探当前机房区域与构建 IPv6 双栈端点
  log("[*] 正在嗅探服务器所在的 OCI 全球区域...")
  inst_meta = get_meta("instance/")
  compartment_id = inst_meta["compartmentId"]
  region = inst_meta.get("canonicalRegionName") or inst_meta.get("region")
  realm_domain = inst_meta.get("regionInfo", {}).get("realmDomainComponent", "oraclecloud.com")

  endpoint = f"https://iaas.{region}.ds.oci.{realm_domain}"
  log(f"[*] 匹配区域: {region} | 双栈接入端点: {endpoint}")

  vnic_meta = get_meta("vnics/")
  vnic_id = vnic_meta[0]["vnicId"]

  # 2. 内存预载实例主体鉴权（解决拔掉 IPv4 后的鉴权死锁）
  log("[*] 正在初始化 OCI 实例主体鉴权...")
  signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
  client = oci.core.VirtualNetworkClient(config={}, signer=signer, service_endpoint=endpoint)

  # 3. 获取主私网 IP 与当前公网 IP
  private_ips = client.list_private_ips(vnic_id=vnic_id).data
  primary_ip_id = private_ips[0].id

  pub_ip_details = oci.core.models.GetPublicIpByPrivateIpIdDetails(private_ip_id=primary_ip_id)
  try:
    public_ip = client.get_public_ip_by_private_ip_id(pub_ip_details).data
    old_public_ip_id = public_ip.id
    log(f"[*] 找到旧公网 IP: {public_ip.ip_address} (ID: {old_public_ip_id})")
  except Exception:
    old_public_ip_id = None
    log("[*] 当前网卡未绑定公网 IP，将直接申请新 IP。")

  # 4. 删除旧 IP
  if old_public_ip_id:
    log("[*] 正在释放旧公网 IP...")
    client.delete_public_ip(public_ip_id=old_public_ip_id)
    log("[*] 等待 8 秒让私网 IP 状态彻底解锁...")
    time.sleep(8)

  # 5. 申请新临时公网 IP
  log("[*] 正在申请分配全新临时公网 IP...")
  create_details = oci.core.models.CreatePublicIpDetails(
      compartment_id=compartment_id,
      lifetime="EPHEMERAL",
      private_ip_id=primary_ip_id,
  )
  new_ip_resp = client.create_public_ip(create_details)
  new_ip = new_ip_resp.data.ip_address
  log(f"[+] OCI 换 IP 成功！新公网 IP 为: {new_ip}")

  with open("/root/current_ip.txt", "w") as f:
    f.write(new_ip + "\n")

  # 6. 等待 3 秒恢复网络路由，开始触发 Cloudflare DDNS
  time.sleep(3)
  log("[*] 正在触发 Cloudflare DDNS 覆盖记录...")
  update_cloudflare_dns(
      cf_token=config["cf_api_token"],
      zone_id=config["cf_zone_id"],
      record_id=config["cf_record_id"],
      domain_name=config["cf_domain"],
      new_ip=new_ip,
      proxied=config.get("cf_proxied", False),
  )

  # 7. 调用 ip-api.com 获取新 IP 地理信息
  verify_ip_api()
  log("[+] 整体任务执行完毕！")


if __name__ == "__main__":
  main()