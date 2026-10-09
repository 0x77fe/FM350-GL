# 回归验证

覆盖恢复与会话计时、全局/拨号开关、IPv6 升级和信息快照、设备缓存、网络接口配置、路由解析、请求邮箱、实例锁、串口锁、视图渲染与安装失败路径。

## 模拟测试（Linux 构建机或 OpenWrt）

```sh
busybox ash tests/regression.sh
sh tests/install-failures.sh
busybox ash tests/parse-samples.sh
```

`regression.sh` 用模拟 AT、网络与配置操作覆盖零字节冻结计时、流量变化重置、USB 失败尝试的冷却与总恢复超时、成功动作才启动会话宽限期、profile 禁用失败保留待处理状态并冷却重试/重新启用取消、state.json 区分待断开与失败、IPv6 连续刷新失败升级后在 reset wait 跳过串口且恢复后继续采集、整体超时后仍采集但保留 RECOVERING、AT ERROR 分类与进程失败状态、IPv4 / IPv6 接口改名和 alias 切换、跨守护重启归属保持、冲突不触碰用户 section、无归属旧接口仅告警保留、重复对账不重载、设备拔出后清除缓存、默认路由解析、并发请求不覆盖、实例锁释放、串口互斥，以及配置缓存。并发邮箱、实例锁、AT 传输和串口锁用例需要 `flock`；未提供时会明确标记为 `SKIP`。

`install-failures.sh` 用系统 POSIX `sh` 启动。模拟包管理器记录参数；每个负向用例同时断言预期失败原因与安装器调用情况，并通过参数日志确认安装脚本子进程实际调用了 `uname` mock。覆盖 ipk 依赖失败、主包失败、apk 安装失败与缺文件、缺失/空白/格式错误/哈希不符的依赖清单、无效 `META`、本地自编主包不能绕过依赖校验，以及只安装清单内文件。不使用宿主包数据库。

`parse-samples.sh` 用桩 `at_run` 校验厂商解析与 AT 判定：频段与带宽换算、NR/LTE 小区字段、CESQ 有效位与 255/缺失降级、载波聚合已激活/未激活/无 PCC，以及 ERROR 与 OK 同时出现时拒绝更新快照。样本按 AT 手册字段构造，接入模组后应替换为真实抓包（尤其 `AT+GTDNS` 的响应格式尚无实测）。

## 视图测试（任意装有 Node.js ≥ 18 的机器）

```sh
node tests/views-smoke.mjs
```

`views-smoke.mjs` 在桩 DOM 与桩 LuCI API 上执行六个视图模块，覆盖富数据/空数据渲染、原位刷新（拨号状态、当前问题、运营商、信号、载波聚合、快照年龄/不可用状态）、离开页面后轮询自动注销、快捷按钮与拨号操作调用，以及 `require` 名称与已安装文件的对应关系。

## 路由器测试（已备份、已装测试包且未接模组的测试机）

```sh
sh tests/router-smoke.sh
sh tests/installed-content.sh
```

冒烟脚本临时修改管理器与拨号开关、停止/启动守护，并测试真实 RPC 的邮箱占用行为；退出时恢复配置并重启守护。内容检查逐一比较已安装文件及生成的 `/usr/share/fm350/config.template`，排除应保留用户内容的 `/etc/config/fm350`。

## 构建校验

公共构建流程在 `build/common.sh`（SDK 元数据、下载与解压、编译、取产物），`build/build-apk.sh` 与 `build/build-ipk.sh` 只保留包格式差异；`build/build.sh` 是 Docker 入口，只在容器里准备宿主依赖。`build/verify-apk.sh` 在假根安装本包与依赖占位包，禁用安装钩子、检查真实安装退出码，核对 21 个源码文件和由 UCI 配置生成的 `config.template`（共 22 个文件）。安装钩子由测试机的实际包安装覆盖。

离线目录（`dist/deps-apk`、`dist/deps-ipk`）的版本、架构与内核 ABI 来自同目录 `META`；依赖清单 `SHA256SUMS` 只含第三方依赖，主包由 `APP-SHA256SUMS` 管理。本地自编包用于测试时需 `FM350_LOCAL_APP=1` 显式放行，正式发布前必须更新 `APP-SHA256SUMS`。

2026-10-10 收尾验证：构建机 `kiar@192.168.31.9` 的 BusyBox ash 回归（25 组）、系统 sh 安装测试、解析样本（含 CA）全部通过，具备 `flock` / `jq`，无跳过项；本地 Node 视图测试及构建机 shell 语法检查通过。接口回归包含真实主循环：拒绝用户 LAN 和同名 device section 后不探测拨号、不改地址、不重载，纠正配置后恢复管理。

`192.168.4.2`（ImmortalWrt 25.12.1 / apk）与 `192.168.4.3`（ImmortalWrt 24.10.5 / opkg）均升级到 r43，通过安装内容检查（21 个文件，含配置模板，排除用户 UCI 配置）及 RPC/开关冒烟测试；原配置已保留并恢复，最终状态为 `ABSENT`。

本轮版本为 `1.0.0-r43`，使用 ImmortalWrt 25.12.1 SDK 与 OpenWrt 24.10.5 SDK 构建。发布下载清单锚定 `v1.0.0-r43` 的 APK/IPK 文件名与 SHA-256，发布时成对上传并核对 Release 资产 digest。`views-smoke.mjs` 按 luci.js 的契约校验 `require` 模块必须返回 Class 子类，并可直接指向路由器下发的资源目录复核已装文件。两台测试机未连接模组；真实拨号、USB 重枚举、数据面假死及运营商 IPv6 恢复仍需硬件演练。
