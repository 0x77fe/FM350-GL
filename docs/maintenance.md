# 维护

## 构建

公共流程在 `build/common.sh`（SDK 元数据、下载与校验、解压、编译、按 Makefile 版本取产物），`build-apk.sh` 与 `build-ipk.sh` 只保留包格式与版本差异。

```sh
sh build/build-apk.sh     # dist/luci-app-fm350-<版本>-r<release>.apk
sh build/build-ipk.sh     # dist/luci-app-fm350_<版本>-r<release>_all.ipk
sh build/verify-apk.sh    # 假根安装 + 与源码逐文件比对
```

| 环境变量 | 含义 | 默认 |
|---|---|---|
| `FM350_SDK_FLAVOR` | `immortalwrt` / `openwrt` | `immortalwrt` |
| `FM350_SDK_VER` | SDK 与固件版本 | apk：25.12.1；ipk：24.10.6 |
| `FM350_WORK` | 缓存与解压后的 SDK | `$HOME/fm350` |
| `FM350_SDK_DIR` | 已解压 SDK，给出即跳过下载解压 | 空 |
| `FM350_SDK_BASE` | SDK 镜像基址 | 按 `sdk_meta` 取镜像 |
| `FM350_DIST` | 产物输出目录 | `dist/` |

`build/build.sh` 是 Docker 入口，只在容器里装 glibc 宿主依赖（SDK 自带的 fakeroot 需要 glibc，容器用 debian），随后调用 `build-ipk.sh`，SDK 落在 `FM350_CACHE`。

两套包内文件逐字节相同（`PKGARCH=all`），差别只在包格式、包管理器与内核依赖。

## 离线目录

`dist/deps-ipk/`（24.10 · opkg）与 `dist/deps-apk/`（25.12+ · apk）结构相同，互不通用。

| 文件 | 作用 |
|---|---|
| `META` | 固件版本、目标架构、包架构、内核版本、kmods ABI；下载脚本与安装预检共同读取 |
| `SHA256SUMS` | 第三方依赖清单，只含依赖 |
| `APP-SHA256SUMS` | 自建主包的唯一锚点：确切文件名 + 发布时的 sha256 |
| `download.sh` / `download.ps1` | 联网取依赖与主包并校验，两个入口行为一致 |
| `install_all.sh` | 在路由器上离线安装：读 `META` 预检内核与基础包，按清单校验并只安装清单内的文件 |

```sh
sh dist/deps-apk/download.sh                 # 取依赖 + 主包
FM350_NO_APP=1 sh dist/deps-apk/download.sh  # 只取依赖
FM350_LOCAL_APP=1 sh dist/deps-apk/download.sh   # 用本目录自编主包，跳过发布哈希校验
FM350_RELEASE_BASE=<镜像前缀> sh dist/deps-apk/download.sh   # 换主包来源
FM350_CURL_OPTS=--ssl-no-revoke sh dist/deps-apk/download.sh # Git Bash 证书吊销检查失败时
```

本地自编主包用于测试时，安装侧同样需要显式放行：`FM350_LOCAL_APP=1 sh install_all.sh`。自编包与 `APP-SHA256SUMS` 不一致属于正常现象，发布前必须更新该清单。

换固件版本（含小版本）需要重抓依赖：改 `META`（或 `FM350_VER=` / `FM350_ABI=`）后跑 `sh build/fetch-deps-apk.sh`。`FM350_ABI` 未给出时读 `META`，显式留空则自动探测，探测到多个候选会列出并失败。

## 安装与升级

- 离线安装按包管理器选对应目录，步骤见 [README.md](../README.md#快速安装)。
- 升级主包：路由器上执行同目录 `install_all.sh`，或 `apk add --allow-untrusted <包>` / `opkg install <包>`。
- 安装后 `rpcd` 必须重启，否则 ubus 对象 `fm350` 不注册，页面无数据。
- 守护操作只用 `/etc/init.d/fm350mgr restart`。
- 升级后浏览器可能继续使用旧的前端副本：LuCI 静态 JS 在这些固件上不带 `Cache-Control`（`uhttpd` 的 `no_cache` 选项不生效），资源 URL 形如 `?v=<luciversion>-<包数据库 mtime>`，只在装包后变化。升级脚本会 touch JS 文件刷新 ETag 并提示强制刷新；页面仍异常时先按 Ctrl+Shift+R 或在开发者工具里勾选 Disable cache 再刷新，再确认已装文件与源码一致（`tests/installed-content.sh`）。
- 24.10 老 modem 链路（luci-app-modem / ModemManager）：`deploy/install_fm350.sh` 默认调用 `deploy/migrate_modem.sh`，可用 `FM350_SKIP_MIGRATE=1` 跳过，`FM350_MIGRATE_BACKUP=<目录>` 指定备份位置。迁移把旧脚本、rc 链接、热插拔脚本与 `/etc/config/modem` 移入 `/root/backup/fm350-legacy-<时间戳>`，并生成 `MANIFEST` 与 `rollback.sh`；还原用 `sh deploy/rollback_fm350.sh [备份目录]`，不依赖 `/var/trash`。

## 发布

1. 确定版本：改 `luci-app-fm350/Makefile` 的 `PKG_RELEASE`（`PKG_VERSION` 变更时同步调整）。
2. 构建两种包并从源码侧实证：`sh build/build-apk.sh`、`sh build/build-ipk.sh`、`sh build/verify-apk.sh`（apk 假根安装 + 逐文件比对），ipk 用 `ar`/`tar` 解出 control 与 data 后逐文件比对。
3. 在测试机升级并跑 `tests/installed-content.sh`、`tests/router-smoke.sh`，确认菜单与守护正常；前端改动还要按 luci.js 的 `require` 契约验证（`node tests/views-smoke.mjs`，可直接指向路由器下发的资源目录），必要时在浏览器里实际打开页面复核。
4. 用产物刷新 `dist/deps-*/APP-SHA256SUMS`（确切文件名 + sha256）并提交。
5. 在该提交上打标签 `v<PKG_VERSION>-r<PKG_RELEASE>` 并推送，标签版本必须与包内版本一致。
6. 成对上传：`gh release create <标签> <apk> <ipk> --title <标签> --notes <一句话功能与支持平台>`；发布后用 `gh release view <标签> --json assets` 的 digest 与本地 sha256 复核，并确认 `releases/latest/download/<包名>` 可下载。
7. 第三方依赖不进 Release，仍由下载脚本从官方镜像取；只发布其中一种包会让离线目录的主包校验失败。

## 测试

| 脚本 | 位置 | 覆盖 |
|---|---|---|
| `regression.sh` | 构建机 / 路由器 | 恢复计时、开关、IPv6 升级、请求邮箱、实例锁、串口互斥、配置校验与缓存 |
| `install-failures.sh` | 构建机 / 路由器 | 安装负向路径与清单驱动的文件选择 |
| `parse-samples.sh` | 构建机 / 路由器 | 厂商解析样本（手册字段，接入模组后替换为真实抓包） |
| `views-smoke.mjs` | 任意 Node ≥ 18 | 六个视图模块的渲染、原位刷新、轮询注销、require 解析 |
| `router-smoke.sh` / `installed-content.sh` | 测试机 | 真实 RPC 与开关行为、已安装内容与源码比对 |

细节与运行命令见 [tests/README.md](../tests/README.md)。

## 排障

| 现象 | 处理 |
|---|---|
| 页面无数据 | `/etc/init.d/rpcd restart`；`ubus list \| grep fm350` 确认对象注册 |
| 状态长期 ABSENT | 查 `logread \| grep fm350`；`sh /usr/lib/fm350/fm350.sh check` 看发现与探测结果 |
| kmod 安装被拒 | `META` 的内核 ABI 与固件不一致，重抓对应版本依赖 |
| 主包校验失败 | `APP-SHA256SUMS` 未按当前产物更新，或用了自编包而没有 `FM350_LOCAL_APP=1` |
| 出现双实例 | 只用 `/etc/init.d/fm350mgr restart`；`flock` 单实例锁会拒绝第二个实例 |
| 界面停留在旧版 | uhttpd 缓存：`uci set uhttpd.main.no_cache='js'` 后重启 uhttpd |

恢复演练用 `deploy/simulate.sh`（IPv6 / IPv4 / 拔线三种场景，会中断网络，需保证管理连接走独立 LAN）。
