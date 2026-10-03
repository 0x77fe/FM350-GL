# dist/deps-apk —— 离线安装包（apk 体系，OpenWrt / ImmortalWrt 25.12+）

目标固件：**ImmortalWrt 25.12.x / x86-64 / kernel 6.12.94**
kmods ABI 目录：`6.12.94-1-0413601b1c3f0490e17f340fe09229ea`

> OpenWrt 25.12 起包管理器由 **opkg 换成 apk**（apk-tools 3），包格式是 `.apk`；
> 24.10 那套 ipk 离线依赖在这里**不可复用**，见 [../deps-ipk/README.md](../deps-ipk/README.md)。

## 本目录内容（仓库里**没有二进制**）

| 文件 | 作用 |
|---|---|
| `download.sh` | 在**联网的 Windows/Linux 机器**上按 `SHA256SUMS` 从官方源（含镜像）下载 19 个依赖并逐一校验，再按 `APP-SHA256SUMS` 从 GitHub Release 取回预编译主包（Linux / macOS / Git Bash / WSL） |
| `download.ps1` | 同上，Windows 原生 PowerShell 实现（Windows 10+ 自带 PowerShell 与 bsdtar，**不需要 Git Bash / WSL**） |
| `install_all.sh` | 在**路由器**上离线安装（`apk add --network=no`），自带 ABI 预检与双重校验（`SHA256SUMS` + `APP-SHA256SUMS`） |
| `SHA256SUMS` | 19 个第三方依赖的确切文件名与 sha256（本项目的包不在其中） |
| `APP-SHA256SUMS` | **主包** `luci-app-fm350-*.apk` 的文件名与 sha256（发布锚点，下载脚本据此从 Release 取回） |
| `README.md` | 本文件 |

第三方二进制（GPL-2.0-only 的内核模块等）**不入库**，由 `download.sh`（Linux）或 `download.ps1`（Windows）从官方镜像取得；
本项目自己的包 `luci-app-fm350-*.apk` 同样不入库，由下载脚本按 `APP-SHA256SUMS` 从 GitHub Release 取回
（也可在构建机上 `sh build/build-apk.sh` 编译后拷进本目录）。

## 依赖清单

| 类别 | 包 | 版本 |
|---|---|---|
| USB 主控 | kmod-usb-core / kmod-usb-common / kmod-nls-base / kmod-usb2 / kmod-usb3 / kmod-usb-xhci-hcd / kmod-usb-ehci / kmod-usb-ohci | 6.12.94-r1 |
| 数据面 | kmod-usb-net / kmod-usb-net-cdc-ether / kmod-usb-net-rndis / kmod-mii / kmod-libphy | 6.12.94-r1 |
| 串口（AT 口） | kmod-usb-serial / kmod-usb-serial-wwan / kmod-usb-acm / kmod-usb-wdm | 6.12.94-r1 |
| 用户态 | jq / sms-tool | 1.8.1-r2 / 2025.08.23~491ffdb0-r1 |

合计 19 个 apk（约 350 KB）。`kmod-nls-base` 是 `kmod-usb-core` 的依赖，漏了它整条 USB 链路装不上。

固件自带、因此**不需要下载**：`libc`、`luci-base`、`rpcd`、`odhcp6c`、`odhcpd-ipv6only`
（25.12.x 官方/ImmortalWrt x86/64 镜像均自带；`install_all.sh` 会预检，缺了会明确报错）。

## 用法（两步）

**方式一 · Linux / macOS（或 Windows 上的 Git Bash / WSL）**（命令在仓库根目录执行）

```sh
# 1) 联网的 Windows/Linux 机器：依赖（官方镜像，7 秒左右）+ 预编译主包（GitHub Release）一次下齐并校验
sh dist/deps-apk/download.sh
#    想自己编主包：sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist/deps-apk/

# 2) 传到路由器，离线安装（dropbear 没有 sftp-server，OpenSSH 9+ 默认走 SFTP 会直接失败 → 用 tar 管道最省事；
#    若用 scp 则必须带 -O 走旧的 SCP 协议）
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

> Windows 上的 **Git Bash** 若报 `curl: (35) schannel: CRYPT_E_REVOCATION_OFFLINE`（Git 自带 curl 走 Schannel，
> 联网校验证书吊销列表失败），加 `FM350_CURL_OPTS=--ssl-no-revoke` 即可：
> `FM350_CURL_OPTS=--ssl-no-revoke sh dist/deps-apk/download.sh`；或改用下面的 `download.ps1`（不受这个问题影响）。

**方式二 · Windows 原生（PowerShell，不需要 Git Bash / WSL）**

```powershell
# 1) 依赖 + 预编译主包一次下齐并校验（与 download.sh 等价：同一份 SHA256SUMS / APP-SHA256SUMS、同一套镜像回落顺序）
#    -ExecutionPolicy Bypass 是为了免去改执行策略
powershell -ExecutionPolicy Bypass -File dist\deps-apk\download.ps1

# 2) 传到路由器再离线安装（以下命令在仓库根目录执行）
#    · PowerShell 里的 tar 管道会把二进制当文本处理而损坏 → 先打成 tar.gz 再传；
#    · scp 必须带 -O：dropbear 没有 sftp-server，OpenSSH 9+ 默认的 SFTP 协议会直接失败；
#    · tar / scp / ssh 都是 Windows 10+ 自带的（bsdtar + OpenSSH 客户端），无需另装。
tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .
scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

> `download.ps1` 支持与 `download.sh` 相同的开关（命令行参数优先于环境变量）：
> `-Version`（`FM350_VER`）、`-Abi`（`FM350_ABI`）、`-Mirrors`（`FM350_MIRRORS`）、
> `-ReleaseBase`（`FM350_RELEASE_BASE`，主包来源前缀）。

## 主包从哪来（GitHub Release）

本目录**不放二进制**。自建主包发布在 [GitHub Releases](https://github.com/0x77fe/FM350-GL/releases/latest)，
文件名与 sha256 钉在 `APP-SHA256SUMS`；下载脚本跑完依赖后会据此取回并校验（取不到会明确报错并非 0 退出）。
国内访问 GitHub 慢或不可达时：

```sh
FM350_RELEASE_BASE=https://<镜像或代理前缀> sh dist/deps-apk/download.sh
# 或完全绕开 Release：在构建机上编好再拷进来
sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist/deps-apk/
```

主包升级（换 r 号或改依赖）时，Release 传新包并同步更新 `APP-SHA256SUMS` 的文件名与 sha256。

`install_all.sh` 做 6 步：预检固件自带依赖与内核 ABI → 校验 `SHA256SUMS` 与 `APP-SHA256SUMS` → 装 kmod 与 jq/sms-tool →
装主包 → `rpcd restart` + uhttpd `no_cache=js` → 启守护并打印状态（含 ubus 对象是否注册）。

## 校验

- `download.sh` / `download.ps1` 每下一个包都用 `SHA256SUMS` 里的 sha256 比对，**校验不过就不落盘**（会换下一个镜像重试）；
  主包同理按 `APP-SHA256SUMS` 校验后才落盘。
- 安装前 `install_all.sh` 再整体 `sha256sum -c SHA256SUMS` 与 `-c APP-SHA256SUMS`，失败即中止并提示回联网的 Windows/Linux 机器重跑下载脚本。
- `apk verify --allow-untrusted <包>` → `OK` 表示 apk 自洽性（内容校验和）通过。
- 自建的主包未签名，所以安装统一 `apk add --allow-untrusted`（25.12 自建包的标准做法）。

## 镜像选择

`download.sh` 默认按 **NJU → USTC → PKU → 官方** 顺序尝试（`FM350_MIRRORS` 可覆盖；`download.ps1` 用 `-Mirrors`）。实测结论：

- `mirror.nju.edu.cn`：~350KB/s，目录列表完整；
- `mirrors.ustc.edu.cn`：快，但**目录列表被截断**（kmods 缺 `kmod-usb-common`/`kmod-usb-wdm`）——本脚本按文件名直取，不受影响；
- `mirrors.pku.edu.cn`：很快，但目录页是 JS 空壳（列不出文件名）；
- `downloads.immortalwrt.org`：最全，国内 ~5KB/s。

四个源的同一文件 sha256 一致：实测 NJU 抓的 19 个包与官方源**哈希完全相同**。

## 换固件版本时怎么重新生成清单

kmod 与固件内核 ABI 强绑定，**换版本必须重抓**（apk 会拒绝装错版本的内核模块）：

```sh
# 在构建机上：重新生成依赖（自动写 SHA256SUMS 与 fetch 结果）
FM350_VER=25.12.2 FM350_ABI=<新 ABI> sh build/fetch-deps-apk.sh
# 重新生成主包
sh build/build-apk.sh
```

## 实机验证

2026-09-30 在一台 ImmortalWrt 25.12.1 / kernel 6.12.94 / **无外网**的 x86-64 测试机上跑
`download.sh` → 传目录 → `install_all.sh`：19 个依赖校验通过、主包装上、
`ubus list` 出现 `fm350`、`ubus call fm350 status` 返回合法 JSON（state=ABSENT，该机未接模组）、
守护单实例运行、开机自启已启用、`rpcd`/`uhttpd` 就绪。重复执行（覆盖安装）同样通过。

2026-10-03 Windows 侧 `download.ps1` 验证（Windows PowerShell 5.1，空目录起步）：
19 个依赖约 4 秒从 NJU 下齐并逐一校验通过，产物与 `download.sh` 抓到的**哈希完全一致**，无 `.new` 残留。

## 与 dist/deps-ipk 的区别

| | deps-ipk | deps-apk（本目录） |
|---|---|---|
| 目标固件 | ImmortalWrt 24.10.x x86_64 | ImmortalWrt 25.12.x x86_64 |
| 内核 / ABI | 6.6.122 | 6.12.94 |
| 包管理器 | opkg（`.ipk`） | apk-tools 3（`.apk`） |
| 安装 | `opkg install` | `apk add --allow-untrusted`（`--network=no`） |
| 依赖数 | 17 | 19 |
