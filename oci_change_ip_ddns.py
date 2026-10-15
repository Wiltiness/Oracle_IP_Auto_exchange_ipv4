#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import os
import re
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


def get_ip_api_info():
  """调用 ip-api.com 获取国家码和地区信息"""
  try:
    req = urllib.request.Request(
        "http://ip-api.com/json/", headers={"User-Agent": "curl/8.0"}
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
      info = json.loads(resp.read().decode("utf-8"))
      if info.get("status") == "success":
        return info
  except Exception as e:
    log(f"[*] ip-api.com 探针提示: {e}")
  return {}


def cf_request(url, token, method="GET", data=None):
  headers = {
      "Authorization": f"Bearer {token}",
      "Content-Type": "application/json",
  }
  body = json.dumps(data).encode("utf-8") if data else None
  req = urllib.request.Request(url, data=body, headers=headers, method=method)
  with urllib.request.urlopen(req, timeout=10) as resp:
    return json.loads(resp.read().decode("utf-8"))


def sync_cloudflare_ddns(cf_token, zone_id, full_domain, new_ip, proxied=False):
  """根据 Cloudflare 文档自动覆盖或新建 A 记录"""
  query_url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records?name={full_domain}&type=A"
  try:
    search_res = cf_request(query_url, cf_token, method="GET")
    records = search_res.get("result", [])

    payload = {
        "name": full_domain,
        "ttl": 60,
        "type": "A",
        "comment": (
            "Auto-updated by OCI auto-switcher at"
            f" {time.strftime('%Y-%m-%d %H:%M:%S')}"
        ),
        "content": new_ip,
        "proxied": proxied,
    }

    if records:
      # 记录已存在，使用官方文档中推荐的 PUT 覆盖
      record_id = records[0]["id"]
      put_url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}"
      res = cf_request(put_url, cf_token, method="PUT", data=payload)
      if res.get("success"):
        log(
            f"[+] Cloudflare DNS (PUT覆盖) 成功: {full_domain} -> {new_ip}"
            f" (Proxied: {proxied})"
        )
        return True
    else:
      # 记录不存在，自动 POST 创建
      post_url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records"
      res = cf_request(post_url, cf_token, method="POST", data=payload)
      if res.get("success"):
        log(
            f"[+] Cloudflare DNS (POST新建) 成功: {full_domain} -> {new_ip}"
            f" (Proxied: {proxied})"
        )
        return True

    log(f"[-] Cloudflare 操作未成功: {res.get('errors')}")
    return False
  except Exception as e:
    log(f"[-] Cloudflare API 通信异常: {e}")
    return False


def main():
  config = load_config()

  # 1. 自动探测实例信息与双栈端点
  log("[*] 正在嗅探服务器所在的 OCI 全球区域...")
  inst_meta = get_meta("instance/")
  compartment_id = inst_meta["compartmentId"]
  instance_id = inst_meta["id"]
  region = inst_meta.get("canonicalRegionName") or inst_meta.get("region")
  region_key = (
      inst_meta.get("regionInfo", {}).get("regionKey", "unknown").lower()
  )
  realm_domain = inst_meta.get("regionInfo", {}).get(
      "realmDomainComponent", "oraclecloud.com"
  )

  endpoint = f"https://iaas.{region}.ds.oci.{realm_domain}"
  log(f"[*] 匹配区域: {region} ({region_key}) | 双栈接入端点: {endpoint}")

  vnic_meta = get_meta("vnics/")
  vnic_id = vnic_meta[0]["vnicId"]

  # 2. 内存预载实例主体鉴权
  log("[*] 正在初始化 OCI 实例主体鉴权...")
  signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
  client = oci.core.VirtualNetworkClient(
      config={}, signer=signer, service_endpoint=endpoint
  )

  # 3. 释放旧 IP
  private_ips = client.list_private_ips(vnic_id=vnic_id).data
  primary_ip_id = private_ips[0].id
  pub_ip_details = oci.core.models.GetPublicIpByPrivateIpIdDetails(
      private_ip_id=primary_ip_id
  )
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

  # 4. 申请新临时公网 IP
  log("[*] 正在申请分配全新临时公网 IP...")
  create_details = oci.core.models.CreatePublicIpDetails(
      compartment_id=compartment_id,
      lifetime="EPHEMERAL",
      private_ip_id=primary_ip_id,
  )
  new_ip_resp = client.create_public_ip(create_details)
  new_ip = new_ip_resp.data.ip_address
  log(f"[+] OCI 换 IP 成功！新分配的公网 IP: {new_ip}")

  with open("/root/current_ip.txt", "w") as f:
    f.write(new_ip + "\n")

  time.sleep(3)

  # 5. 调用 ip-api.com 获取真实国家码
  ip_info = get_ip_api_info()
  country_code = ip_info.get("countryCode", "xx").lower()
  log(
      f"[*] 出口定位探测: 国家={country_code.upper()} | 城市={ip_info.get('city')}"
      f" | ISP={ip_info.get('isp')}"
  )

  # 6. 计算拼装专属 DDNS 域名：实例OCID后4位-地区码-国家码-租户名.根域名
  ocid_last4 = instance_id[-4:].lower()
  tenant_name = config.get("tenant_name", "landscap").lower()
  base_domain = config.get("base_domain", "").strip(".")

  subdomain_prefix = (
      f"{ocid_last4}-{region_key}-{country_code}-{tenant_name}".lower()
  )
  subdomain_prefix = re.sub(r"[^a-z0-9\-]", "", subdomain_prefix)
  full_ddns_domain = f"{subdomain_prefix}.{base_domain}"

  log(f"[*] 自动计算生成的专属 DDNS 域名: {full_ddns_domain}")

  # 7. 同步更新 Cloudflare
  sync_cloudflare_ddns(
      cf_token=config["cf_api_token"],
      zone_id=config["cf_zone_id"],
      full_domain=full_ddns_domain,
      new_ip=new_ip,
      proxied=config.get("cf_proxied", False),
  )
  log("[+] 本轮任务圆满完成！")


if __name__ == "__main__":
  main()
