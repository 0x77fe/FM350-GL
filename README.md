# FM350-GL 管理器（luci-app-fm350）

ImmortalWrt 24.10 / 25.12 上的 Fibocom FM350-GL 5G 模组管理器：**拨号生命周期的唯一 owner + 分级自动恢复 + 模块全自动发现 + LuCI2 中文管理界面**。

面向的固件缺陷（本模块固件层面无法修复）：随机 USB 断开/假死（AT 与 PDP 活着但数据面冻结）；运行久后 IPv6 不自动刷新（IPv4 正常、IPv6 失效）；模块可能被拔线/移位。本管理器将上述问题的**感知、分级恢复、配置化**全部自动化。

| 项 | 值 |
|---|---|
| 目标固件 | ImmortalWrt 24.10.5 x86_64（kernel 6.6.122，opkg）与 25.12.x（kernel 6.12.94，apk） |
| 模组 | Fibocom FM350-GL，USB `0e8d:7127`（**VID:PID 亦自动识别**，无需预知） |
| 数据面 | RNDIS → `eth2`（netifd 静态 v4 + dhcpv6/odhcp6c） |
| 包名 | `luci-app-fm350`（当前 r36）；离线安装按体系分两份：`dist/deps-ipk/`（24.10 · opkg）、`dist/deps-apk/`（25.12+ · apk） |
| 预编译包 | [Releases](https://github.com/0x77fe/FM350-GL/releases/latest)：`luci-app-fm350-1.0.0-r36.apk`（25.12+/apk）、`luci-app-fm350_1.0.0-r36_all.ipk`（24.10/opkg）；下载脚本会自动取回并校验，见 [1.10](#110-离线安装路由器不联网) |
| 业务链路 | AT 口 `/dev/ttyUSB1`（自动探测）、APN ctnet、PDP ipv4v6、上下文 3 |

---

# 完整工作原理

## 1.1 组件架构

```mermaid
flowchart TB
    subgraph 内核["内核 / 固件层（厂商无关）"]
        USB["USB 枚举<br/>rndis_host → ethX<br/>usbserial → ttyUSB*"]
        NETIFD["netifd + odhcp6c + odhcpd"]
    end

    subgraph 守护["fm350mgr 守护（procd 常驻 · 单进程单循环 · 单实例锁）"]
        MAIN["fm350.sh<br/>主循环（5s）"]
        LIB_D["lib/discover.sh<br/>USB/网卡/AT口/VID:PID 自动发现"]
        LIB_AT["lib/at.sh<br/>sms_tool 封装 + 看门狗"]
        LIB_P["lib/probe.sh<br/>分层探测（只读）"]
        LIB_DIAL["lib/dial.sh<br/>拨号 / 接口 / 刷新"]
        LIB_REC["lib/recover.sh<br/>分级恢复动作"]
        VENDOR["fibocom.sh<br/>厂商私有 AT（信息类，可降级）"]
        STATE[("/var/run/fm350/<br/>state.json 快照<br/>events.log 事件")]
    end

    subgraph UI["管理界面层"]
        UCODE["rpcd ucode 后端<br/>ubus 对象 fm350"]
        JS["LuCI2 JS（6 页）<br/>dash/detail/atcon/dialop/config/fm350logs"]
        ACL["ACL / menu.d"]
    end

    CFG["UCI /etc/config/fm350"]

    USB -->|"sysfs 扫描"| LIB_D
    LIB_D --> MAIN
    MAIN --> LIB_AT -->|"AT 命令"| USB
    MAIN --> LIB_P --> NETIFD
    MAIN --> LIB_DIAL -->|"uci + ifup/reload"| NETIFD
    MAIN --> LIB_REC
    LIB_DIAL --> VENDOR
    MAIN -->|"写快照/事件"| STATE
    CFG --> MAIN
    STATE --> UCODE --> JS
    JS -->|"指令（原子队列 req）"| MAIN
    ACL --> JS
```

**分层原则**：恢复动作与探测完全厂商无关；厂商私有内容只有三个函数（`AT+GTDNS` 取 DNS、`AT+GTCCINFO` 取信号/小区、可选预设 `GTAUTODHCP/GTIPPASS/GTAUTOCONNECT`），**失败时全部降级**（DNS 用公共兜底、信号显示原始串），不影响上网主链路。

## 1.2 主循环（每 5s 一轮，唯一状态机）

```mermaid
flowchart TD
    A["discover_light()<br/>缓存路径校验（廉价）"] -->|"缓存失效"| B["discover_scan()<br/>（含 discover_auto）"]
    A -->|"路径有效"| C{"USB 存在?"}
    B --> C
    C -->|"否"| ABS["状态=ABSENT<br/>记录离线时刻 / 超时告警"]
    C -->|"是"| D["handle_req()<br/>消费 UI 指令（原子队列）"]
    D --> E{"profile.enable?"}
    E -->|"0"| DIS["状态=DISABLED"]
    E -->|"1"| F["discover_ifname / discover_at_port<br/>dial_ensure_interfaces（幂等）"]
    F --> G["probe_v4_at()<br/>AT+CGPADDR=cid"]
    G -->|"空 / 0.0.0.0"| DIAL["重拨（60s 节流）<br/>+ escalate_v4 阶梯"]
    G -->|"有效"| H{"uci 地址 ≠ 模块地址?"}
    H -->|"是"| REF["refresh_v4()<br/>改 uci + network reload + ifup"]
    H --> I["假死检测<br/>计数冻结 ∧ 公共DNS不可达<br/>（120s 宽限期内不判）"]
    I -->|"确认假死"| USBR["USB 级复位 → 直接 L3"]
    I --> J["probe_v4_kernel()<br/>默认路由校验"]
    J -->|"丢失"| ESC["escalate_v4()"]
    J --> K["IPv6 校验<br/>地址+路由+ping6 2400:3200::1"]
    K -->|"硬故障"| V6R["escalate_v6()<br/>仅刷新 wwan6（不动模组）"]
    K -->|"ping 不通（软）"| V6S["30 分钟兜底前缀刷新"]
    K --> L["模组快照（30s ATI/CPIN/COPS<br/>120s GTCCINFO）"]
    L --> M["write_state()<br/>state.json 原子落盘"]
```

## 1.3 三个"全自动"发现（不依赖任何固定值）

| 发现项 | 机制 | 失效/复位后的表现 |
|---|---|---|
| **USB VID:PID** | 配置 `usb_vid_pid` 留空 = 自动：遍历 USB 设备（排除 hub）→ 对各自串口探测 `ATI` 应答特征（`FM350\|Fibocom\|Manufacturer`）→ 命中即模组，读取其 VID:PID/路径/设备节点 | 换口/换机型无需改配置；识别结果缓存进 `state.usb.vid/pid` 并在事件日志留痕 |
| **网卡名** | `RNDIS/ECM` 网卡位于设备路径 `*/net/*`（回退 `/sys/class/net` 反查 device 归属）→ 自动得到 `ethX`；变化时自动重建 netifd `device=` 绑定 | 端口漂移、`eth2→eth0` 均自适应 |
| **AT 口** | 配置留空：遍历 `/dev/ttyUSB*` 探测 `ATI`（带看门狗）；自动识别命中时其串口直接作为 AT 口；全扫带 60s 冷却 | 重枚举后编号漂移无碍（实测 `ttyUSB1`↔`ttyUSB4` 漂移） |

> 手动兼容：三项均可通过配置显式指定（`usb_vid_pid=0e8d:7127`、`at_port=/dev/ttyUSB1`）。

## 1.4 状态机（对外状态 = `state.json.state`）

```mermaid
stateDiagram-v2
    [*] --> ABSENT: 启动 / USB 不可见
    ABSENT --> PRESENT: 设备重新枚举
    note right of ABSENT
        记录离线时刻；
        超过 reappear_timeout 告警，
        每 10 分钟提醒一次
    end note

    PRESENT --> DIALING: AT 口/网卡就绪
    DIALING --> ONLINE: CGPADDR 有地址 ∧ 路由正常
    DIALING --> RECOVERING: 拨号失败进入阶梯
    ONLINE --> RECOVERING: 掉线 / 假死 / v6 硬故障
    RECOVERING --> ONLINE: 验证通过（接口+路由+探测）
    ONLINE --> DIALING: 模块重启 / 地址清空
    RECOVERING --> ABSENT: USB 复位触发重枚举
    ONLINE --> DISABLED: UI 停用拨号
    DISABLED --> DIALING: UI 启用
```

状态含义：`ABSENT` 模块离线 ｜ `PRESENT` 已发现待拨号 ｜ `DIALING` 拨号中 ｜ `ONLINE` 在线 ｜ `RECOVERING` 恢复流程进行（含 `problem` 细分：`v4/v6/data/absent` 与恢复级别）｜ `DISABLED` 用户停用。

## 1.5 分级恢复阶梯（"对症下药"核心）

```mermaid
flowchart TD
    START["故障确认（v4/v6/假死）"] --> L0{"L0 等待<br/>wait_timeout=180s"}
    L0 -->|"超时未愈"| L1["L1 重建接口<br/>ifup wwan_5g_0 / wwan6_5g_0"]
    L1 -->|"recovery_timeout=300s"| L2["L2 软重启模组<br/>AT+CFUN=0/1 + 重拨<br/>（cooldown=300s 限一次）"]
    L2 -->|"usb_reset_timeout=600s"| L3["L3 USB 级复位<br/>unbind/bind（可用 usbreset 兜底）"]
    L3 -->|"restart_timeout=1800s"| ALARM["告警循环（记录+UI 红色状态）<br/>随后重新从 L0 计程"]
    ALARM --> L0

    FROZEN["数据面假死<br/>计数冻结 ∧ 公共DNS不可达"] -->|"直接"| L3
    V6["IPv6 硬故障（地址/路由丢失）"] --> V6R["仅刷新 wwan6_5g_0<br/>（odhcp6c 重刷，不动模组）"]
    V6R -->|"60s 重试 ≤3 次仍失败"| L1
    V6S["IPv6 软故障（ping 不通但地址在）"] --> V6T["30 分钟兜底刷新<br/>（判定上游问题，不重启模组）"]
```

设计要点：

- **每一级动作后必须重新探测验证**，成功即归位 `ONLINE`，失败才升级；全程**不触碰 `lan`**；
- **假死专项**：判据为"网卡计数冻结 **且** 公共 DNS（默认 202.101.224.69）不可达"——`ping` 网关不做判据（实测 CTNET 网关 ICMP 被过滤，健康会话也 100% 丢包）；计数在动而 ping 不通视为上游问题，**绝不动模组**；
- **宽限期**：重拨/换 IP/USB 复位后 120s 内不判假死（避免刚上线的新会话被误复位），`sess_since` 持久化到 state，守护重启不丢；
- **IPv6 专项**：默认只 `ifdown/ifup wwan6_5g_0`（秒级、不断 IPv4），连续失败才升级；软故障只做 30 分钟兜底刷新；
- 所有动作节流幂等（`cooldown`），任何时刻至多一个执行者（单实例锁 + 指令队列）。

## 1.6 拨号与网络建立时序

```mermaid
sequenceDiagram
    participant G as 守护 fm350mgr
    participant M as FM350 模组（AT）
    participant N as netifd
    participant O as odhcp6c/odhcpd

    G->>M: AT+COPS=0,0（自动选网）
    G->>M: AT+CGDCONT=3,"IPV4V6","CTNET"
    opt presets_enabled=1（默认关）
        G->>M: GTAUTODHCP / GTIPPASS / GTAUTOCONNECT
    end
    G->>M: AT+CGACT=1,3（激活 PDP）
    loop 每 5s
        G->>M: AT+CGPADDR=3（权威 IPv4）
    end
    G->>N: uci 静态 v4（IP/掩码/网关/DNS）+ dhcpv6(extendprefix)
    G->>N: service network reload + ifup wwan_5g_0 / wwan6_5g_0
    N->>O: 启动 dhcpv6 客户端（取前缀）
    O-->>N: 前缀 240e:xxxx::/64（每连接会变）
    G->>G: 校验 接口+默认路由+ping → ONLINE
```

地址变化即**热刷新**：`CGPADDR` 与 uci 不一致 → 更新 uci（新 IP/网关 `${ipv4%.*}.1`/运营商 DNS）→ reload + ifup，无需重启模组。

## 1.7 UI 数据流与指令队列（零竞争设计）

```mermaid
flowchart LR
    subgraph 守护侧
        DAEMON["守护"] -->|"30s：ATI/CPIN/COPS<br/>120s：GTCCINFO"| SNAP["state.json<br/>at / cell / net / usb 快照"]
        DAEMON -->|"事件"| EV["events.log<br/>（200 条上限自动裁剪）"]
    end
    subgraph 前端
        SNAP -->|"读快照（快、无竞争）"| RPC["rpcd ucode<br/>status/cell/events/logs"]
        BTN["页面按钮"] -->|"inbox 写入<br/>（.new + rename 原子）"| REQ["/var/run/fm350/req"]
    end
    REQ -->|"守护每轮 mv 消费<br/>（决不清空竞态）"| DAEMON
    RPC -->|"ACL 鉴权"| VIEW["LuCI2 页面（每 5s 轻量刷新）"]
```

- **UI 永不直接抢串口**：模组信息走守护快照（`status`/`cell` 后端"快照优先"），只有 AT 控制台是用户主动的实时执行（带 15s 看门狗 + 20s 无响应告警）；
- **指令队列原子化**：前端写 `req.new` 后 `rename` 生效，守护 `mv req req.done` 消费——两侧均不会读到半成品（历史教训：`open('w')` 截断会与读取竞态产生空指令）。

## 1.8 文件与日志治理（防膨胀）

| 对象 | 策略 |
|---|---|
| `events.log` | 超过 `events_keep`（默认 200）自动删最旧行 |
| 日志页显示 | 仅渲染最近 80 行/条 |
| AT 临时文件 | 每进程固定单文件复用 + RPC 用后立即清空 + 守护启动 `cleanup_stale()` 清理（实测治理前 100 文件/420KB → 治理后 28KB/1 个非空） |
| 系统 syslog | 由系统 logd 环形缓冲管理；本包仅事件级输出 |

## 1.9 部署与运维规范

```bash
# 远程构建 · ipk（ImmortalWrt 24.10 / opkg：开发服务器 docker + ImmortalWrt SDK 24.10.6）
# （另见 build/build-apk.sh：构建机 <build-host> 直跑 OpenWrt 25.12 官方 SDK 出 apk，无需 docker）
sh build/build.sh                      # 产物 dist/luci-app-fm350_<ver>_all.ipk
# 同一件事不用 docker 的做法（构建机是 Linux 即可）：直跑 ImmortalWrt 24.10.6 SDK
sh build/build-ipk.sh                  # 产物 dist/luci-app-fm350_<ver>-r<rel>_all.ipk

# 远程构建 · apk（OpenWrt 25.12+ / apk：构建机 <build-host> 直跑官方 SDK）
sh build/build-apk.sh                  # 产物 dist/luci-app-fm350-<ver>-r<rel>.apk（PKGARCH=all）
# 目标固件是 ImmortalWrt 时用它的 SDK（默认就是）：FM350_SDK_FLAVOR=immortalwrt
# 刷新 apk 离线依赖包（换固件版本/ABI 后必做）：sh build/fetch-deps-apk.sh
# 校验产物（假根安装 + 逐文件比对）：sh build/verify-apk.sh

# 路由器安装 · 24.10/opkg（离线：在联网的 Windows/Linux 机器上跑下面这条，依赖 + 预编译主包一次下齐，见 1.10.1）
sh dist/deps-ipk/download.sh
tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"

# 路由器安装 · 25.12/apk（离线：同上，依赖 + 预编译主包一次下齐，见 1.10.2）
sh dist/deps-apk/download.sh
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"

# 日常运维（务必只用 restart；勿手动 kill/start，procd respawn 会与之叠加出双实例）
ssh root@<router> "/etc/init.d/fm350mgr restart"
```

> **两套体系不可互换**：包内文件一致（29 个文件逐字节相同），差别只在安装体系与内核依赖 ——
> 25.12 起包管理器由 opkg 换成 apk（apk-tools 3），自建包不在官方密钥内，必须 `apk add --allow-untrusted`；
> 官方/ImmortalWrt x86/64 镜像**不含任何 `kmod-usb-*`**（USB 主控 / RNDIS / 串口驱动全要装），
> 而 kmod 与内核 ABI 强绑定（24.10 = 6.6.122，25.12.1 = 6.12.94）。
> 离线安装两套做法见 **1.10**，依赖清单与来源见各自的 `dist/deps-*/README.md`。

- **单实例锁**：`daemon.pid` + 存活校验，第二实例自动退出（日志：`已有守护实例运行中`）；
- 安装脚本内置：卸旧包（先 i18n 后主包，`--force-depends` 兜底）、`rpcd restart`（否则 RPC 对象不注册）、uhttpd `no_cache=js`、静态资源 `touch`（破解浏览器启发式缓存）；
- 恢复演练与回滚：`deploy/simulate.sh`（IPv6/IPv4/拔线三场景）、`deploy/rollback_fm350.sh`；
- 参考存档：`baseline/`（旧链路完整存档，**第三方参考件，不入库**，见 `.gitignore`）、`dist/deps-ipk/README.md` 与 `dist/deps-apk/README.md`（两套依赖的版本与来源）。

---

## 1.10 离线安装（路由器不联网）

两套体系各一份离线安装目录，**互不通用**（内核 ABI 与包管理器都不同）。
仓库**不含任何二进制**（含第三方 GPL 二进制与自建包）：第三方依赖由 `download.sh`（Linux）或
`download.ps1`（Windows 原生 PowerShell，二者等价）在**联网的 Windows/Linux 机器**上按
`SHA256SUMS` 从官方镜像现取并校验；**本项目自建的主包已发布到
[Releases](https://github.com/0x77fe/FM350-GL/releases/latest)**，下载脚本按 `APP-SHA256SUMS`
（文件名 + 发布时钉死的 sha256）一并取回并校验 —— 于是用户侧不需要编译，仓库里只有脚本与清单。

| | `dist/deps-ipk/` | `dist/deps-apk/` |
|---|---|---|
| 目标固件 | ImmortalWrt **24.10.x** x86_64 | ImmortalWrt **25.12.x** x86_64 |
| 内核 / kmods ABI | 6.6.122 / `6.6.122-1-e7e50fbc…` | 6.12.94 / `6.12.94-1-0413601b…` |
| 包管理器 | opkg（`.ipk`） | apk-tools 3（`.apk`） |
| 依赖清单 | 17 个（`SHA256SUMS` 内） | 19 个（`SHA256SUMS` 内） |
| 取依赖 | `sh download.sh`（Linux）｜`download.ps1`（Windows） | 同左 |
| 取主包 | 下载脚本按 `APP-SHA256SUMS` 从 GitHub Release 取回预编译包；取不到可 `FM350_RELEASE_BASE` 换镜像或自行编译 | 同左 |
| 装 | `install_all.sh`（`opkg install`） | `install_all.sh`（`apk add --network=no`） |

两个安装脚本结构相同：**预检**（固件自带基础包 + 内核/ABI）→ **校验 `SHA256SUMS` 与 `APP-SHA256SUMS`** → 装依赖 →
装主包 → `rpcd restart` + uhttpd `no_cache=js` → 启守护并打印状态（含 ubus 对象是否注册）。
预检不通过或校验失败会**明确报错并退出**，不会留下半装状态。

> 传输：Linux 用 `tar` 管道（OpenWrt 的 dropbear 不带 sftp-server，新版本 OpenSSH 客户端走 SFTP 协议会直接失败）；
> Windows 用自带的 `tar`（bsdtar）+ `scp -O`——PowerShell 里的管道会把二进制当文本处理而损坏，所以先打成 `.tar.gz` 再传。
> Windows 上的 **Git Bash** 跑 `download.sh` 若报 `curl: (35) schannel: CRYPT_E_REVOCATION_OFFLINE`，
> 加 `FM350_CURL_OPTS=--ssl-no-revoke`，或直接用 `download.ps1`。
> 主包来自 GitHub Release，国内可能慢或不可达：`FM350_RELEASE_BASE=<镜像/代理前缀>` 可换源；
> 也可以完全不用 Release —— 在构建机上编译（`build/build-apk.sh` / `build/build-ipk.sh`）后把产物拷进对应目录。

### 1.10.1 ipk 离线安装（ImmortalWrt 24.10 及以前 · opkg）

**Linux**（或 Windows 上的 Git Bash / WSL）：

```sh
# 1) 联网的 Windows/Linux 机器：依赖（官方镜像，约 7 秒）+ 预编译主包（GitHub Release）一次下齐并校验
sh dist/deps-ipk/download.sh
#    想自己编主包：sh build/build-ipk.sh && cp dist/luci-app-fm350_*.ipk dist/deps-ipk/

# 2) 送到路由器 → 离线安装
tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

**Windows 原生**（PowerShell，不需要 Git Bash / WSL；以下命令在仓库根目录执行）：

```powershell
# 1) 依赖 + 预编译主包一次下齐并校验（等价于 sh download.sh）
powershell -ExecutionPolicy Bypass -File dist\deps-ipk\download.ps1

# 2) 打包送到路由器 → 离线安装
tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .
scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

装：`kmod-usb-{core,2,3,ehci,ohci,xhci-hcd,net,net-cdc-ether,net-rndis,serial,serial-wwan,acm,wdm}`、
`jq`、`sms-tool`、`odhcp6c`、`odhcpd-ipv6only` + 自建的 `luci-app-fm350_*.ipk`。

### 1.10.2 apk 离线安装（OpenWrt / ImmortalWrt 25.12 及以后）

**Linux**（或 Windows 上的 Git Bash / WSL）：

```sh
# 1) 联网的 Windows/Linux 机器：依赖（官方镜像，约 7 秒）+ 预编译主包（GitHub Release）一次下齐并校验
sh dist/deps-apk/download.sh
#    想自己编主包：sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist/deps-apk/

# 2) 送到路由器 → 离线安装
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

**Windows 原生**（PowerShell，不需要 Git Bash / WSL；以下命令在仓库根目录执行）：

```powershell
# 1) 依赖 + 预编译主包一次下齐并校验（等价于 sh download.sh）
powershell -ExecutionPolicy Bypass -File dist\deps-apk\download.ps1

# 2) 打包送到路由器 → 离线安装
tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .
scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

装：`kmod-usb-{core,common,nls-base,2,3,xhci-hcd,ehci,ohci,net,net-cdc-ether,net-rndis,serial,serial-wwan,acm,wdm}`、
`kmod-{mii,libphy}`、`jq`、`sms-tool` + 自建的 `luci-app-fm350-*.apk`。
`kmod-nls-base` 是 `kmod-usb-core` 的依赖，漏了整条 USB 链路装不上。

> 换了固件版本（哪怕只是 25.12.1 → 25.12.2）都要**重新抓一套**：
> `FM350_VER=… FM350_ABI=… sh build/fetch-deps-apk.sh`（apk 侧；它会重写 `SHA256SUMS`），
> 主包由 `sh build/build-apk.sh` 产出。ipk 侧同理，kmod 必须与固件内核 ABI 完全一致。
> 主包升级（换 r 号）：构建机出包 → 传到 Release → 更新对应 `dist/deps-*/APP-SHA256SUMS` 里的文件名与 sha256。

---
