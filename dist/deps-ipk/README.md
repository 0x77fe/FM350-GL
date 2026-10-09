# dist/deps-ipk —— 离线安装（ipk 体系）

| 项 | 值 |
|---|---|
| 目标固件 | ImmortalWrt / OpenWrt 24.10.x x86_64 |
| 内核与 kmods ABI | 6.6.122 / `6.6.122-1-e7e50fbc0aafa7443418a79928da2602`（见 `META`） |
| 包管理器 | opkg（`.ipk`） |
| 依赖 | 17 个，清单见 `SHA256SUMS` |
| 主包 | `luci-app-fm350_*.ipk`，锚点见 `APP-SHA256SUMS` |

与 apk 体系互不通用（内核 ABI 与包管理器都不同），对应目录为 [`../deps-apk`](../deps-apk/README.md)。

## 目录内容

| 文件 | 作用 |
|---|---|
| `META` | 固件版本、目标架构、包架构、内核版本、kmods ABI |
| `SHA256SUMS` | 17 个第三方依赖的文件名与 sha256，只含依赖 |
| `APP-SHA256SUMS` | 自建主包的确切文件名与发布 sha256，唯一锚点 |
| `download.sh` / `download.ps1` | 联网取依赖与主包并逐个校验，两个入口行为一致 |
| `install_all.sh` | 路由器上离线安装：预检内核与基础包 → 按清单校验 → 只安装清单内的文件 |
| `*.ipk` | 依赖包与主包（仓库不含二进制，由下载脚本取回） |

依赖：`kmod-usb-{core,2,3,ehci,ohci,xhci-hcd,net,net-cdc-ether,net-rndis,serial,serial-wwan,acm,wdm}`、`jq`、`sms-tool`、`odhcp6c`、`odhcpd-ipv6only`。`libc`、`libubox*`、`libubus*`、`luci-base`、`rpcd` 由固件自带，安装脚本会预检。

## 使用

联网机器（Linux / macOS / Git Bash / WSL）：

```sh
sh download.sh
tar -czf - -C . . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

Windows 原生 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File download.ps1
tar -czf "$env:TEMP\deps-ipk.tar.gz" -C . .
scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

环境变量：`FM350_NO_APP=1` 只取依赖、`FM350_LOCAL_APP=1` 放行本目录自编主包、`FM350_RELEASE_BASE=<前缀>` 换主包来源、`FM350_CURL_OPTS=--ssl-no-revoke`（Git Bash 证书吊销检查失败时）。本地自编包用于测试时，安装侧同样加 `FM350_LOCAL_APP=1`。

传输注意：OpenWrt 的 dropbear 不带 sftp-server，OpenSSH 9+ 客户端默认走 SFTP 会失败，用 `tar` 管道或 `scp -O`。

## 换固件版本

内核模块必须与固件内核完全一致。改 `META`（或 `FM350_VER=` / `FM350_ABI=`）后按对应版本重新获取依赖；主包由 `sh build/build-ipk.sh` 产出。

构建、发布与排障见 [../../docs/maintenance.md](../../docs/maintenance.md)。
