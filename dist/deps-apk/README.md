# dist/deps-apk —— 离线安装包（apk 体系，OpenWrt / ImmortalWrt 25.12+）

目标固件：**ImmortalWrt 25.12.x / x86-64 / kernel 6.12.94**
kmods ABI 目录：`6.12.94-1-0413601b1c3f0490e17f340fe09229ea`

> OpenWrt 25.12 起包管理器由 **opkg 换成 apk**（apk-tools 3），包格式是 `.apk`；
> 24.10 那套 ipk 离线依赖在这里**不可复用**，见 [../deps-ipk/README.md](../deps-ipk/README.md)。

## 本目录内容（仓库里**没有二进制**）

| 文件 | 作用 |
|---|---|
| `download.sh` | 在**联网的开发机**上按 `SHA256SUMS` 从官方源（含镜像）下载 19 个依赖并逐一校验 |
| `install_all.sh` | 在**路由器**上离线安装（`apk add --network=no`），自带 ABI 预检与校验 |
| `SHA256SUMS` | 19 个第三方依赖的确切文件名与 sha256（本项目的包不在其中） |
| `README.md` | 本文件 |

第三方二进制（GPL-2.0-only 的内核模块等）**不入库**，由 `download.sh` 取得；
本项目自己的包 `luci-app-fm350-*.apk` 由 `build/build-apk.sh` 编译产出后放进本目录。

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

```sh
# 1) 联网的开发机：下依赖并校验（7 秒左右，NJU 镜像）
sh download.sh
#    再把主包编译好放进本目录（仓库不含二进制）：
#    sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist/deps-apk/

# 2) 传到路由器（dropbear 没有 sftp-server，scp 不可用 → 走 tar 管道），离线安装
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

`install_all.sh` 做 6 步：预检固件自带依赖与内核 ABI → 校验 `SHA256SUMS` → 装 kmod 与 jq/sms-tool →
装主包 → `rpcd restart` + uhttpd `no_cache=js` → 启守护并打印状态（含 ubus 对象是否注册）。

## 校验

- `download.sh` 每下一个包都用 `SHA256SUMS` 里的 sha256 比对，**校验不过就不落盘**（会换下一个镜像重试）。
- 安装前 `install_all.sh` 再整体 `sha256sum -c SHA256SUMS`，失败即中止并提示回开发机重跑 `download.sh`。
- `apk verify --allow-untrusted <包>` → `OK` 表示 apk 自洽性（内容校验和）通过。
- 自建的主包未签名，所以安装统一 `apk add --allow-untrusted`（25.12 自建包的标准做法）。

## 镜像选择

`download.sh` 默认按 **NJU → USTC → PKU → 官方** 顺序尝试（`FM350_MIRRORS` 可覆盖）。实测结论：

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

## 与 dist/deps-ipk 的区别

| | deps-ipk | deps-apk（本目录） |
|---|---|---|
| 目标固件 | ImmortalWrt 24.10.x x86_64 | ImmortalWrt 25.12.x x86_64 |
| 内核 / ABI | 6.6.122 | 6.12.94 |
| 包管理器 | opkg（`.ipk`） | apk-tools 3（`.apk`） |
| 安装 | `opkg install` | `apk add --allow-untrusted`（`--network=no`） |
| 依赖数 | 17 | 19 |

许可证清单见 [../../docs/licenses.md](../../docs/licenses.md)。
