# dist/deps-ipk —— 离线安装包（ipk 体系，ImmortalWrt / OpenWrt 24.10 及以前）

目标固件：**ImmortalWrt 24.10.x / x86_64 / kernel 6.6.122**
kmods ABI 目录：`6.6.122-1-e7e50fbc0aafa7443418a79928da2602`

> 24.10 用 **opkg**（`.ipk`）。25.12 起换成 **apk**（`.apk`），两套离线依赖不能混用，
> 见 [../deps-apk/README.md](../deps-apk/README.md)。

## 本目录内容（仓库里**没有二进制**）

| 文件 | 作用 |
|---|---|
| `download.sh` | 在**联网的 Windows/Linux 机器**上按 `SHA256SUMS` 从官方源（含镜像）下载 17 个依赖并逐一校验，再按 `APP-SHA256SUMS` 从 GitHub Release 取回预编译主包（Linux / macOS / Git Bash / WSL） |
| `download.ps1` | 同上，Windows 原生 PowerShell 实现（Windows 10+ 自带 PowerShell 与 bsdtar，**不需要 Git Bash / WSL**） |
| `install_all.sh` | 在**路由器**上离线安装（`opkg install`），自带内核版本预检与双重校验（`SHA256SUMS` + `APP-SHA256SUMS`） |
| `SHA256SUMS` | 17 个第三方依赖的确切文件名与 sha256（本项目的包不在其中） |
| `APP-SHA256SUMS` | **主包** `luci-app-fm350_*.ipk` 的文件名与 sha256（发布锚点，下载脚本据此从 Release 取回） |
| `README.md` | 本文件 |

第三方二进制（GPL-2.0 的内核模块与 odhcp6c/odhcpd-ipv6only 等）**不入库**，由 `download.sh`（Linux）或 `download.ps1`（Windows）从官方镜像取得；
本项目自己的包 `luci-app-fm350_*.ipk` 同样不入库，由下载脚本按 `APP-SHA256SUMS` 从 GitHub Release 取回
（也可在构建机上 `sh build/build-ipk.sh`——直跑 ImmortalWrt 24.10.6 SDK，无需 docker——编译后拷进本目录）。

## 依赖清单

| 类别 | 包 | 版本 |
|---|---|---|
| USB 主控 | kmod-usb-core / usb2 / usb3 / usb-ehci / usb-ohci / usb-xhci-hcd | 6.6.122-r1 |
| 数据面 | kmod-usb-net / kmod-usb-net-cdc-ether / kmod-usb-net-rndis | 6.6.122-r1 |
| 串口（AT 口） | kmod-usb-serial / kmod-usb-serial-wwan / kmod-usb-acm / kmod-usb-wdm | 6.6.122-r1 |
| 用户态 | jq / sms-tool | 1.8.1-r1 / 2023.09.21~1b6ca032-r1 |
| IPv6 | odhcp6c / odhcpd-ipv6only | 2024.09.25~b6ae9ffa-r2 / 2025.10.02~b14cf98c-r3 |

合计 17 个依赖包（约 650 KB）。

固件自带、因此**不需要下载**：`libc`、`libubox`、`libubus`、`luci-base`、`rpcd`
（24.10 镜像均自带；`install_all.sh` 会预检，缺了会明确报错）。

## 用法（两步）

**方式一 · Linux / macOS（或 Windows 上的 Git Bash / WSL）**（命令在仓库根目录执行）

```sh
# 1) 联网的 Windows/Linux 机器：依赖（官方镜像，7 秒左右）+ 预编译主包（GitHub Release）一次下齐并校验
sh dist/deps-ipk/download.sh
#    想自己编主包：sh build/build-ipk.sh && cp dist/luci-app-fm350_*.ipk dist/deps-ipk/

# 2) 送到路由器，离线安装（dropbear 无 sftp-server，OpenSSH 9+ 默认走 SFTP 会直接失败 → 用 tar 管道最稳；
#    若用 scp 则必须带 -O 走旧的 SCP 协议）
tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

> Windows 上的 **Git Bash** 若报 `curl: (35) schannel: CRYPT_E_REVOCATION_OFFLINE`（Git 自带 curl 走 Schannel，
> 联网校验证书吊销列表失败），加 `FM350_CURL_OPTS=--ssl-no-revoke` 即可：
> `FM350_CURL_OPTS=--ssl-no-revoke sh dist/deps-ipk/download.sh`；或改用下面的 `download.ps1`（不受这个问题影响）。

**方式二 · Windows 原生（PowerShell，不需要 Git Bash / WSL）**

```powershell
# 1) 依赖 + 预编译主包一次下齐并校验（与 download.sh 等价：同一份 SHA256SUMS / APP-SHA256SUMS、同一套镜像回落顺序）
#    -ExecutionPolicy Bypass 是为了免去改执行策略
powershell -ExecutionPolicy Bypass -File dist\deps-ipk\download.ps1

# 2) 送到路由器再离线安装（以下命令在仓库根目录执行）
#    · PowerShell 里的 tar 管道会把二进制当文本处理而损坏 → 先打成 tar.gz 再传；
#    · scp 必须带 -O：dropbear 没有 sftp-server，OpenSSH 9+ 默认的 SFTP 协议会直接失败；
#    · tar / scp / ssh 都是 Windows 10+ 自带的（bsdtar + OpenSSH 客户端），无需另装。
tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .
scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

> `download.ps1` 支持与 `download.sh` 相同的开关（命令行参数优先于环境变量）：
> `-Version`（`FM350_VER`）、`-Abi`（`FM350_ABI`）、`-Mirrors`（`FM350_MIRRORS`）、
> `-ReleaseBase`（`FM350_RELEASE_BASE`，主包来源前缀）。

## 主包从哪来（GitHub Release）

本目录**不放二进制**。自建主包发布在 [GitHub Releases](https://github.com/0x77fe/FM350-GL/releases/latest)，
文件名与 sha256 钉在 `APP-SHA256SUMS`；下载脚本跑完依赖后会据此取回并校验（取不到会明确报错并非 0 退出）。
国内访问 GitHub 慢或不可达时：

```sh
FM350_RELEASE_BASE=https://<镜像或代理前缀> sh dist/deps-ipk/download.sh
# 或完全绕开 Release：在构建机上编好再拷进来（build-ipk.sh 直跑 ImmortalWrt 24.10.6 SDK，不需要 docker）
sh build/build-ipk.sh && cp dist/luci-app-fm350_*.ipk dist/deps-ipk/
```

主包升级（换 r 号或改依赖）时，Release 传新包并同步更新 `APP-SHA256SUMS` 的文件名与 sha256。

`install_all.sh` 做 6 步：预检固件自带依赖与内核版本 → 校验 `SHA256SUMS` 与 `APP-SHA256SUMS` → 装依赖包 → 装主包 →
`rpcd restart` + uhttpd `no_cache=js` → 启守护并打印状态（含 ubus 对象是否注册）。

## 镜像选择

`download.sh` 默认按 **NJU → USTC → PKU → 官方** 顺序尝试（`FM350_MIRRORS` 可覆盖；`download.ps1` 用 `-Mirrors`）；
kmod 走 `targets/x86/64/kmods/<ABI>/`，`odhcp6c`/`odhcpd-ipv6only` 走 base feed，
其余走 packages feed。实测 NJU 抓的 17 个包与官方源 sha256 完全一致。

## 注意

- 内核模块版本必须与固件 kernel ABI 完全一致（`6.6.122-1-<hash>`），换固件版本需按
  `SHA256SUMS` 重新生成一套（`build/build-apk.sh` 之外的 ipk 侧目前靠 `build/build.sh` 的 docker 流程）；
- `comgt`（可选 AT 工具）不在官方源中（路由器自带，来自 istore feed），未打包，缺失不影响运行；
- 主包升级只需替换本目录里的 `luci-app-fm350_*.ipk`。

## 实机验证

2026-09-30 在一台 ImmortalWrt 24.10.5 / kernel 6.6.122 的 x86-64 测试机上跑
`download.sh` → 传目录 → `install_all.sh`：17 个依赖校验通过、主包装上、
`ubus list` 出现 `fm350`、守护单实例运行；重复执行（覆盖安装）同样通过。

2026-10-03 Windows 侧 `download.ps1` 校验（Windows PowerShell 5.1）：按 `SHA256SUMS` 逐包比对，
本目录 17 个依赖全部命中「已有」路径（哈希一致即不重复下载），逻辑与 `download.sh` 的等价性由此确认。
