# 📖 OCI 自动换 IP & Cloudflare DDNS 完整使用教程

本文档指导你从零开始配置：
1. **在甲骨文（OCI）控制台做什么**（配置免 API Key 权限）
2. **在 Cloudflare 控制台做什么**（获取 API 密钥与区域 ID）
3. **如何在服务器上一键运行脚本**

---

## 步骤一：在甲骨文（OCI）控制台做什么？

目标：**允许你的虚拟服务器通过自身数字证书免密调用 OCI API 换 IP，无需在机器内放私钥文件。**

### 1. 确认实例已分配 IPv6（关键双栈通道）
* 进入你的实例页面 -> 点击左侧 **Attached VNICs（已连接的 VNIC）** -> 点击主网卡名称；
* 点击左侧 **IPv6 Addresses**，确认机器已经分配了 IPv6 地址（创建机器或 VCN 时一般默认分配；若没有，点击 *Assign IPv6 Address* 自动分配一个即可，完全免费）。

---

### 2. 创建动态组（Dynamic Group）
1. 登录 OCI 控制台，点击左上角导航菜单（三道杠） -> **Identity & Security（身份和安全）** -> **Domains（身份域）**；
2. 点击进入 **`Default`** 身份域；
3. 在页面正上方的横向标签栏中，点击 **`Dynamic groups`（动态组）**；
4. 点击 **Create dynamic group**：
   * **Name（组名）**：填 `IP_EDIT_ACCESS`
   * **Matching rule（匹配规则）**：填入你的机器 OCID（多台机器用逗号隔开）：
     ```text
     Any {
       instance.id = '你的第一台机器OCID',
       instance.id = '你的第二台机器OCID'
     }
     ```
   * 点击创建。

---

### 3. 创建授权策略（Policy）
1. 回到左上角导航菜单 -> **Identity & Security** -> **Identity** -> 点击 **`Policies`（策略）**；
2. **注意**：确保左侧的 Compartment（区间）选择的是**最顶层的根区间 `(root)`**；
3. 点击 **Create Policy**：
   * **Name（策略名）**：填 `IP_EDIT_ACCESS_POLICY`
   * 打开 **Manual Editor（手动编辑器）** 开关，粘贴以下 **两行策略**：
     ```text
     Allow dynamic-group 'Default'/'IP_EDIT_ACCESS' to manage virtual-network-family in tenancy
     Allow dynamic-group 'Default'/'IP_EDIT_ACCESS' to inspect tenancies in tenancy
     ```
     > **说明**：第一句用于免密注销和申请公网 IPv4；第二句用于让脚本 100% 自动读取租户名称。
   * 点击创建保存。

---

## 步骤二：在 Cloudflare 控制台做什么？

目标：**获取用于修改域名解析的 API Token 和 Zone ID。**

### 1. 获取 API Token（具备 DNS 修改权限）
1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com)；
2. 点击右上角个人头像 -> 选择 **My Profile（我的个人资料）**；
3. 点击左侧导航栏的 **API Tokens** -> 点击 **Create Token（创建令牌）**；
4. 找到 **Edit zone DNS（编辑区域 DNS）** 模板，点击其右侧的 **Use template（使用模板）**；
5. 在配置页中：
   * **Zone Resources（区域资源）**：
     * 选择 `Include` -> `Specific zone` -> 选择你的目标域名（如 `example.com`）；
6. 滚动到页面底部，点击 **Continue to summary** -> 点击 **Create Token**；
7. **复制并保存生成的长字符串 Token**（⚠️ 页面关闭后无法再次查看）。

---

### 2. 获取 Zone ID（区域 ID）
1. 点击 Cloudflare 控制台左上角图标，回到主页网站列表；
2. 点击进入你的**域名详情页**（如点击 `example.com`）；
3. 在左侧菜单点击 **Overview（概述）** 页面；
4. 页面向下滑动，在**右侧栏底部**找到 **API** 模块：
   * 找到 **Zone ID**，点击其下方的 **Click to copy（点击复制）**。

---

## 步骤三：在服务器上怎么用脚本？

SSH 登录到你的甲骨文云服务器（以 `root` 用户运行），提供以下两种安装方式：

### 方式 A：交互式向导安装（新手推荐）
直接运行一键安装脚本，终端会一步步提示你输入，回车确认即可：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Wiltiness/Oracle_IP_Auto_exchange_ipv4/master/install_auto_ddns.sh)
```

根据屏幕提示输入：
1. **Cloudflare API Token**
2. **Cloudflare Zone ID**
3. **根域名 / 基础域名**（例如 `example.com`，或者 `node.example.com`）
4. **小黄云代理模式**（直接回车默认关闭 `false`）
5. **换 IP 周期**（直接回车默认每 12 小时 `12h`，支持如 `6h`、`1d` 等）

---

### 方式 B：命令行直接传参（适合批量/脚本一键部署）
无需任何人工交互，一行命令完成所有配置并启动定时任务：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Wiltiness/Oracle_IP_Auto_exchange_ipv4/master/install_auto_ddns.sh) \
  --token "你的Cloudflare_API_Token" \
  --zone "你的Cloudflare_Zone_ID" \
  --domain "example.com" \
  --interval "12h" \
  --proxied false
```

---

## 🎯 最终效果与域名生成规则

安装完成后，脚本每次定时执行时，会自动生成格式如下的专属 DDNS 域名并完成解析更新：

> **`实例OCID后4位-地区码-国家码-租户名.根域名`**

#### 实际效果示例：
* 实例 OCID 后 4 位：`bgfq`
* 所在地区：英国伦敦（`lhr`）
* 出口国家：英国（`gb`）
* 租户名称：`landscap`
* 用户输入的根域名：`example.com`

👉 **最终自动解析的域名：**
```text
bgfq-lhr-gb-landscap.example.com
```

---

## 🛠️ 常用管理命令

```bash
# 1. 立即手动执行一次换 IP 与 DDNS 同步任务
systemctl start oci-ddns.service

# 2. 查看实时运行日志与换 IP 记录
tail -f /var/log/oci_ddns.log

# 3. 查看定时器运行状态及下一次自动触发时间
systemctl status oci-ddns.timer

# 4. 查看当前生效的最新公网 IPv4
cat /root/current_ip.txt
```