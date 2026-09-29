# 许可证与上游依赖清单

> 本文记录本项目的许可、上游代码来源，以及运行时/离线依赖各自的许可证。
> 仓库内**不包含任何第三方二进制**（`.apk` / `.ipk` 均不入库），依赖一律由脚本从官方源下载。

## 1. 本项目

| 项 | 值 |
|---|---|
| 许可证 | **GPL-3.0-only**（全文见仓库根 `LICENSE`，包内另附一份 `luci-app-fm350/LICENSE`） |
| 包元数据 | `luci-app-fm350/Makefile` → `PKG_LICENSE:=GPL-3.0-only`、`PKG_LICENSE_FILES:=LICENSE` |
| 版权 | 本项目各文件由本项目作者创作；`fibocom.sh` 另含上游版权（见下） |

### 为什么是 GPL-3.0 而不是 MIT

`luci-app-fm350/files/usr/lib/fm350/fibocom.sh` 中的信号/小区换算公式与解析结构**抽取并修改自**
[luci-app-modem](https://github.com/qianlyun123/luci-app-modem) v1.4.4（作者 Siriling，`PKG_LICENSE:=GPLv3`）。
按 GPLv3 §5，修改版必须以 GPLv3 授权**整个作品**（§5c），并保留上游版权声明、标注已修改（§5a/§5b）。
因此本包整体以 GPL-3.0-only 发布，且该文件头部带有完整的来源与修改声明。

> 换成 GPL-3.0 之前，本项目曾标为 MIT —— 那与上述派生事实不符，故修正。

其余文件与上游参考实现无实质重合（逐文件行比对见下），仅 `fibocom.sh` 存在派生关系。

### 与上游参考件的重合度（逐文件行集合比对）

| 文件 | 与参考件重合 | 判断 |
|---|---|---|
| `files/usr/lib/fm350/fibocom.sh` | 31 行（含 8 个 `fibocom_get_*` 函数名、若干换算公式） | **派生**，已按 GPLv3 处理 |
| `files/etc/init.d/fm350mgr` | 6 行 | procd 通用骨架（`USE_PROCD`/`start_service`），非表达性内容 |
| 其余 28 个文件 | ≤ 4 行 | 空行/`{`/`}`/JSON 结构/AT 命令字符串等事实性内容 |

## 2. 上游参考件（**不入库**）

| 组件 | 许可证 | 说明 |
|---|---|---|
| luci-app-modem 1.4.4（Siriling） | GPLv3 | 仅作为本地对照参考（`.gitignore` 里的 `baseline/`），仓库不含其源码 |

## 3. 运行时依赖（由固件自身提供）

| 组件 | 许可证 | 说明 |
|---|---|---|
| LuCI（`luci-base`） | Apache-2.0 | 只通过 `require`/RPC 调用其接口，未复制其代码 |
| `rpcd` | ISC | ubus RPC 宿主 |
| `jq` | MIT | 状态快照 JSON 解析（离线包内提供） |
| `sms-tool` | Apache-2.0 | AT 通道（离线包内提供） |

## 4. 离线包内的第三方包（**不入库**，由 `download.sh` 获取）

`dist/deps-ipk/`（ImmortalWrt 24.10.x / kernel 6.6.122 / opkg）与
`dist/deps-apk/`（ImmortalWrt 25.12.x / kernel 6.12.94 / apk）：

| 组件 | 许可证 |
|---|---|
| `kmod-usb-*`、`kmod-nls-base`、`kmod-mii`、`kmod-libphy`（内核模块） | GPL-2.0-only |
| `odhcp6c`、`odhcpd-ipv6only`（仅 ipk 包） | GPL-2.0 |
| `jq` | MIT |
| `sms-tool` | Apache-2.0 |

这些都是**未经修改的官方构建产物**，从 ImmortalWrt 官方源或其镜像下载，
版本与内核 ABI 与目标固件严格对应（见各目录 `README.md` 与 `SHA256SUMS`）。
`SHA256SUMS` 只覆盖第三方依赖，用于下载后校验；本项目自身的包由 `build/` 下的脚本编译产出，不参与该校验。

## 5. 许可兼容性

GPL-3.0-only 与上表中 Apache-2.0 / ISC / MIT / GPL-2.0(-only) 的**独立程序**并存没有问题：
内核模块、`odhcp6c` 等是运行在同一系统上的独立程序（GPLv3 §5 所称的 aggregate），
既非链接也非衍生，各自遵循自己的许可证即可。本项目不分发它们的二进制。
