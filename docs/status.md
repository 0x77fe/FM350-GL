# FM350-GL 管理器 · 现场快照与部署说明

> 快照时间：2026-09-09 19:00 CST（网关 <router>，ImmortalWrt 24.10.5 x86_64）
> 追加：2026-09-30 · 25.12 线（apk 体系）——测试机 **<test-host-2512>** = ImmortalWrt 25.12.1 r37978-cd0a06bfd3fd / x86-64 / kernel 6.12.94（**该机不联网**，apk-tools 3.0.5，uhttpd 监听 :8000）

## 现场状态（部署前基线）

| 项 | 值 |
|---|---|
| 模组 | FM350-GL，USB `0e8d:7127`，路径 `1-3.2`，AT 口 `/dev/ttyUSB1` |
| 注册 | `0,0,"CHN-CT",11`（电信，NR），CPIN=READY |
| IPv4 | eth2 `10.x.x.x/24`（运营商 CGNAT），gw `10.x.x.1`，DNS 202.101.224.69/119.29.29.29 |
| IPv6 | `240e:xxxx:0:xxxx::/64`（运营商前缀，随连接变化），默认路由经 fe80::2，当前可用 |
| 拨号配置 | APN=ctnet，PDP=ipv4v6，上下文=3，rndis 模式 |
| 已知缺陷 | 每 1~3h 随机 USB 断开/假死；运行久后 IPv6 不自动刷新（IPv4 正常）；CSQ 查询无效（99,99），信号取 GTCCINFO? |

## 包内容（luci-app-fm350 1.0.0-r36，GPL-3.0-only）

- 守护 `/usr/lib/fm350/fm350.sh`（procd 常驻 `/etc/init.d/fm350mgr`，respawn）
- 库：`lib/{config,util,at,discover,probe,dial,recover}.sh`，厂商逻辑 `fibocom.sh`
- 配置：`/etc/config/fm350`（模板 `/usr/share/fm350/config.template`）
- UI：LuCI2 JS 五页（概览/AT命令/拨号管理/设置/日志）+ rpcd ucode 后端（ubus `fm350`）
- 状态/事件：`/var/run/fm350/{state.json,events.log,req}`

## 设计要点

1. **全自动扫描**：按 `usb_vid_pid=0e8d:7127` 全局扫 USB；网卡名（ethX）、AT 口、设备节点全部自动推导；模块移口/换网卡名无需改配置，仅记录"位置变更"事件。
2. **单一状态机**：ABSENT→PRESENT→DIALING→ONLINE→RECOVERING，取代原 3 个互相扰动脚本；无热插拔脚本参与（守候轮询即可）。
3. **分级恢复**：L0 等待(180s) → L1 重建接口(300s) → L2 AT+CFUN 软重启（冷却 300s）→ L3 USB unbind/bind 复位 → 告警循环；数据面冻结（计数无变化 ≥30s）直接 L3；全程不动 `lan`。
4. **IPv6 刷新**：v6 地址/路由丢失或 ping6 失败时仅 `ifdown/ifup wwan6_5g_0`（odhcp6c 重刷），不动模组；连续 3 次失败可按配置升级；ping 探测目标固定 `2400:3200::1`（`2400:da00::6666` 实测 100% 丢包不可用）。
5. **模块离线**：USB 消失 → ABSENT 计时，超 `reappear_timeout` 告警；重新出现自动完成拨号，无需人工。
6. **拨号序列**（沿用现网验证路径）：`AT+COPS=0,0` → `AT+CGDCONT=3,"IPV4V6","CTNET"` → `AT+CGACT=1,3` → CGPADDR 取 IP → uci 静态 v4 + dhcpv6，IP 变化自动刷新。

## 构建（已内置 build.sh / build-apk.sh）

- **ipk（ImmortalWrt 24.10 / opkg）**：在 <test-host-2410> 上 `sh build/build.sh` → docker 内下载 ImmortalWrt SDK 24.10.6 x86-64（约 1.5GB 仅首次），`make package/luci-app-fm350/compile`，产物 `dist/luci-app-fm350_<ver>_all.ipk`。
- **apk（25.12+ / apk）**：构建机 `<user>@<build-host>`（Ubuntu 26.04，**无 docker**）直跑官方 SDK，按发行版选 flavor（`FM350_SDK_FLAVOR`）：
  - `immortalwrt`（默认，对应目标固件 25.12.x）：SDK 590MB，来自 PKU 镜像（`downloads.immortalwrt.org` 实测仅 ~7KB/s 下不动），sha256 校验后解压到 `~/fm350/sdk-immortalwrt-25.12.1`；
  - `openwrt`：官方 OpenWrt SDK 25.12.5（271MB，downloads.openwrt.org）；
  - 产物 `dist/luci-app-fm350-<ver>-r<rel>.apk`（arch **noarch**；两版 SDK 编出的包里 29 个文件逐字节相同，可复现同一 sha256）；
  - SDK 自带 base feed 元数据（luci-base/rpcd 已在 `.config`），**无需** `scripts/feeds update`。
- **产物不入库**：仓库只放源码与脚本（`.gitignore` 已封 `.apk`/`.ipk`），第三方 GPL 二进制改由
  `dist/deps-*/download.sh` 现取；许可与上游清单见 [licenses.md](licenses.md)。

## 离线安装（两套体系，各自一个目录 + 脚本；仓库不含二进制）

| | `dist/deps-ipk/` | `dist/deps-apk/` |
|---|---|---|
| 目标 | ImmortalWrt 24.10.x / kernel 6.6.122 / opkg | ImmortalWrt 25.12.x / kernel 6.12.94 / apk-tools 3 |
| 取依赖 | `download.sh`（联网机器，按 `SHA256SUMS` 校验） | `download.sh`（同上） |
| 安装 | `install_all.sh`（opkg） | `install_all.sh`（`apk add --network=no --allow-untrusted`） |
| 依赖数 | 17 | 19 |
| 实机验证 | ✅ 24.10.5 测试机（2026-09-30） | ✅ 25.12.1 测试机（2026-09-30） |

流程（dropbear 无 sftp-server，scp 不可用 → tar 管道）：

```sh
sh dist/deps-apk/download.sh          # 联网机器：下依赖 + 校验（~7 秒）
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

实测结果（两机一致）：预检通过 → `SHA256SUMS` 全 OK → 依赖装齐 → 主包装上 →
`ubus list` 出现 `fm350`、`ubus call fm350 status` 返回合法 JSON（state=ABSENT，本机无模组）、
守护单实例在跑、开机自启已开、`rpcd`/`uhttpd` 就绪（25.12 那台 `:8000` 能取回 `dash.js` 11378 字节）。
换固件版本必须重抓依赖（kmod 与内核 ABI 强绑定）：`FM350_VER=… FM350_ABI=… sh build/fetch-deps-apk.sh`。

## 部署（路由器上执行，按顺序）

```sh
scp dist/luci-app-fm350_<ver>_all.ipk root@<router>:/tmp/
scp deploy/install_fm350.sh root@<router>:/tmp/
ssh root@<router> "sh /tmp/install_fm350.sh /tmp/luci-app-fm350_<ver>_all.ipk"
```

安装流程：备份旧脚本 → 停/禁旧服务（modem/modeminit/watcher/MM）→ 卸载 luci-app-modem/MM（保留 sms-tool/comgt）→ 安装新包 → 旧文件移入 `/var/trash` → 启动守护。网络在整个迁移过程中不中断。

验证：LuCI 服务→FM350 管理；或 `sh /usr/lib/fm350/fm350.sh check`；或 `logread | grep fm350`。

回滚：`sh rollback_fm350.sh`（需备份目录 `/root/backup/fm350` 且在 feed 可用时重装旧包）。

恢复能力测试（用户择机）：`sh simulate.sh`（1=IPv6、2=IPv4、3=拔线、4=只读检查）。

## 遗留实测项（部署后待验证）

- `AT+GTCCINFO?` 在 FM350-GL 上的实际格式（信号页若显示原始串即为解析未匹配，属预期回退）
- IPv6 兜底刷新周期（soft 30 分钟）与运营商前缀回收行为的匹配度
- 长时间运行后的记忆：若自动升级进程内新增逻辑，先 `cp` 备份再改（旧规则：路由器禁 `rm`，用 `mv` 到 /var/trash）
