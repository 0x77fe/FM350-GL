# dist/deps-apk —— 离线安装（apk 体系）

| 项 | 值 |
|---|---|
| 目标固件 | ImmortalWrt / OpenWrt 25.12.x x86/64 |
| 内核与 kmods ABI | 6.12.94 / `6.12.94-1-0413601b1c3f0490e17f340fe09229ea`（见 `META`） |
| 包管理器 | apk（apk-tools 3，`.apk`） |
| 依赖 | 19 个，清单见 `SHA256SUMS` |
| 主包 | `luci-app-fm350-*.apk`，锚点见 `APP-SHA256SUMS` |

与 ipk 体系互不通用（内核 ABI 与包管理器都不同），对应目录为 [`../deps-ipk`](../deps-ipk/README.md)。

## 目录内容

| 文件 | 作用 |
|---|---|
| `META` | 固件版本、目标架构、包架构、内核版本、kmods ABI |
| `SHA256SUMS` | 19 个第三方依赖的文件名与 sha256，只含依赖 |
| `APP-SHA256SUMS` | 自建主包的确切文件名与发布 sha256，唯一锚点 |
| `download.sh` / `download.ps1` | 联网取依赖与主包并逐个校验，两个入口行为一致 |
| `install_all.sh` | 路由器上离线安装：预检内核与基础包 → 按清单校验 → 只安装清单内的文件 |
| `*.apk` | 依赖包与主包（仓库不含二进制，由下载脚本取回） |

依赖：`kmod-usb-{core,common,nls-base,2,3,xhci-hcd,ehci,ohci,net,net-cdc-ether,net-rndis,serial,serial-wwan,acm,wdm}`、`kmod-{mii,libphy}`、`jq`、`sms-tool`。`kmod-nls-base` 是 `kmod-usb-core` 的依赖。`libc`、`luci-base`、`rpcd`、`odhcp6c`、`odhcpd-ipv6only` 由固件自带，安装脚本会预检。

## 使用

联网机器（Linux / macOS / Git Bash / WSL）：

```sh
sh download.sh
tar -czf - -C . . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

Windows 原生 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File download.ps1
tar -czf "$env:TEMP\deps-apk.tar.gz" -C . .
scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

环境变量：`FM350_NO_APP=1` 只取依赖、`FM350_LOCAL_APP=1` 放行本目录自编主包、`FM350_RELEASE_BASE=<前缀>` 换主包来源、`FM350_CURL_OPTS=--ssl-no-revoke`（Git Bash 证书吊销检查失败时）。本地自编包用于测试时，安装侧同样加 `FM350_LOCAL_APP=1`。

传输注意：OpenWrt 的 dropbear 不带 sftp-server，OpenSSH 9+ 客户端默认走 SFTP 会失败，用 `tar` 管道或 `scp -O`。

## 换固件版本

内核模块必须与固件 ABI 完全一致。改 `META`（或 `FM350_VER=` / `FM350_ABI=`）后在构建机执行 `sh build/fetch-deps-apk.sh` 重抓依赖并刷新 `SHA256SUMS` 与 `META`；主包由 `sh build/build-apk.sh` 产出。

构建、发布、迁移与回滚、排障见 [../../docs/maintenance.md](../../docs/maintenance.md)。
