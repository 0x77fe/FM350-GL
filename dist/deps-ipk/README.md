# dist/deps-ipk —— 离线安装包（ipk 体系，ImmortalWrt / OpenWrt 24.10 及以前）

目标固件：**ImmortalWrt 24.10.x / x86_64 / kernel 6.6.122**
kmods ABI 目录：`6.6.122-1-e7e50fbc0aafa7443418a79928da2602`

> 24.10 用 **opkg**（`.ipk`）。25.12 起换成 **apk**（`.apk`），两套离线依赖不能混用，
> 见 [../deps-apk/README.md](../deps-apk/README.md)。

## 本目录内容（仓库里**没有二进制**）

| 文件 | 作用 |
|---|---|
| `download.sh` | 在**联网的开发机**上按 `SHA256SUMS` 从官方源（含镜像）下载 17 个依赖并逐一校验 |
| `install_all.sh` | 在**路由器**上离线安装（`opkg install`），自带内核版本预检与校验 |
| `SHA256SUMS` | 17 个第三方依赖的确切文件名与 sha256（本项目的包不在其中） |
| `README.md` | 本文件 |

第三方二进制（GPL-2.0 的内核模块与 odhcp6c/odhcpd-ipv6only 等）**不入库**，由 `download.sh` 取得；
本项目自己的包 `luci-app-fm350_*.ipk` 由 `build/build.sh` 编译产出后放进本目录。

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

```sh
# 1) 联网的开发机：下依赖并校验（7 秒左右，NJU 镜像）
sh download.sh
#    再把主包编译好放进本目录（仓库不含二进制）：
#    sh build/build.sh && cp dist/luci-app-fm350_*.ipk dist/deps-ipk/

# 2) 送到路由器（dropbear 无 sftp-server 时走 tar 管道最稳），离线安装
tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

`install_all.sh` 做 6 步：预检固件自带依赖与内核版本 → 校验 `SHA256SUMS` → 装依赖包 → 装主包 →
`rpcd restart` + uhttpd `no_cache=js` → 启守护并打印状态（含 ubus 对象是否注册）。

## 镜像选择

`download.sh` 默认按 **NJU → USTC → PKU → 官方** 顺序尝试（`FM350_MIRRORS` 可覆盖）；
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

许可证清单见 [../../docs/licenses.md](../../docs/licenses.md)。
