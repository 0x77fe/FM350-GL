# 回归验证

覆盖恢复计时、全局开关、IPv6 升级、请求邮箱、实例锁、串口锁、视图渲染与安装失败的退出状态。

## 模拟测试（Linux 构建机或 OpenWrt）

```sh
busybox ash tests/regression.sh
busybox ash tests/install-failures.sh
busybox ash tests/parse-samples.sh
```

`regression.sh` 用模拟 AT、网络与配置操作覆盖零字节冻结计时、流量变化重置、自动复位开关与冷却、600 秒 USB 升级门槛、IPv6 三次刷新后的持续升级、并发请求不覆盖、设备缺席时停用、关闭管理器不探测、实例锁释放、串口互斥，以及配置缓存（合法值生效、非法值回退默认、无缓存时直查 uci）。

`install-failures.sh` 用模拟包管理器覆盖 ipk 依赖失败、主包失败、apk 安装失败与缺文件，并校验清单驱动的安装选择：`APP-SHA256SUMS` 与主包不符时拒绝安装（提示 `FM350_LOCAL_APP=1` 放行方式）、放行后选用本地最新主包、版本号更高或清单外的包不会被安装。不使用宿主包数据库。

`parse-samples.sh` 用桩 `at_run` 校验厂商解析：频段与带宽换算、NR/LTE 小区字段、CESQ 有效位与 255/缺失降级、载波聚合已激活/未激活/无 PCC。样本按 AT 手册字段构造，接入模组后应替换为真实抓包（尤其 `AT+GTDNS` 的响应格式尚无实测）。

## 视图测试（任意装有 Node.js ≥ 18 的机器）

```sh
node tests/views-smoke.mjs
```

`views-smoke.mjs` 在桩 DOM 与桩 LuCI API 上执行六个视图模块，覆盖富数据/空数据渲染、原位刷新（拨号状态、当前问题、运营商、信号、载波聚合）、离开页面后轮询自动注销、快捷按钮与拨号操作调用，以及 `require` 名称与已安装文件的对应关系。

## 路由器测试（已备份、已装测试包且未接模组的测试机）

```sh
sh tests/router-smoke.sh
sh tests/installed-content.sh
```

冒烟脚本临时修改管理器与拨号开关、停止/启动守护，并测试真实 RPC 的邮箱占用行为；退出时恢复配置并重启守护。内容检查逐一比较已安装文件，排除应保留用户内容的 `/etc/config/fm350`。

## 构建校验

公共构建流程在 `build/common.sh`（SDK 元数据、下载与解压、编译、取产物），`build/build-apk.sh` 与 `build/build-ipk.sh` 只保留包格式差异；`build/build.sh` 是 Docker 入口，只在容器里准备宿主依赖。`build/verify-apk.sh` 在假根安装本包与依赖占位包，禁用安装钩子、检查真实安装退出码，并按源码清单反向核对全部 21 个文件（含 `/www/luci-static/resources/fm350/common.js`）。安装钩子由测试机的实际包安装覆盖。

离线目录（`dist/deps-apk`、`dist/deps-ipk`）的版本、架构与内核 ABI 来自同目录 `META`；依赖清单 `SHA256SUMS` 只含第三方依赖，主包由 `APP-SHA256SUMS` 管理。本地自编包用于测试时需 `FM350_LOCAL_APP=1` 显式放行，正式发布前必须更新 `APP-SHA256SUMS`。

2026-10-09 验证环境：Linux 原生 SDK 构建机（apk：ImmortalWrt 25.12.1 SDK；ipk：OpenWrt 24.10.5 SDK）、ImmortalWrt 25.12.1（apk / kernel 6.12.94）、ImmortalWrt 24.10.5（opkg / kernel 6.6.122）。两台路由器均未连接模组，真实拨号、USB 重枚举、数据面假死及运营商 IPv6 恢复仍需硬件演练。

r39 是测试构建，尚未更新 Release 与离线目录的发布校验清单。
