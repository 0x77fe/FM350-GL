# FM350-GL 管理器（luci-app-fm350）

ImmortalWrt 上的 Fibocom FM350-GL 5G 模组管理器：拨号生命周期的唯一 owner、分级自动恢复、模组全自动发现、LuCI 中文管理界面。

针对固件层面无法修复的缺陷：随机 USB 断开或数据面假死（AT 与 PDP 正常但计数冻结）、长时间运行后 IPv6 不再刷新、模组拔插后编号漂移。管理器把这些问题变成可配置的感知与分级恢复。

| 项 | 值 |
|---|---|
| 目标固件 | ImmortalWrt 24.10.x x86_64（kernel 6.6.122 · opkg）与 25.12.x x86_64（kernel 6.12.94 · apk） |
| 模组 | Fibocom FM350-GL，USB `0e8d:7127`（VID:PID 可留空自动识别） |
| 数据面 | RNDIS → `ethX`，netifd 静态 IPv4 + dhcpv6（odhcp6c） |
| 默认业务链路 | AT 口自动探测、APN `ctnet`、PDP `ipv4v6`、上下文 3 |
| 包 | `luci-app-fm350`，`PKGARCH=all`，GPL-3.0-only |
| 预编译包 | [Releases](https://github.com/0x77fe/FM350-GL/releases/latest)（apk 与 ipk 成对发布，见 [docs/maintenance.md](docs/maintenance.md)） |
| 菜单 | 服务 → FM350 管理：状态总览、详情表、AT 命令、拨号管理、设置、日志 |

## 快速安装

路由器不联网时用离线目录（仓库不含二进制，依赖由下载脚本按清单从官方镜像取回，主包按 `APP-SHA256SUMS` 从 Release 取回）。

**24.10 / opkg**

```sh
sh dist/deps-ipk/download.sh
tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
```

**25.12+ / apk**

```sh
sh dist/deps-apk/download.sh
tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

Windows 原生 PowerShell 用同目录 `download.ps1`（与 `download.sh` 行为一致），传输用自带 `tar` + `scp -O`：

```powershell
powershell -ExecutionPolicy Bypass -File dist\deps-apk\download.ps1
tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .
scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/
ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
```

安装后只用 `/etc/init.d/fm350mgr restart` 操作守护；手动 kill/start 会与 procd respawn 叠加出双实例。

## 支持范围

- 已按 AT 手册实现并以模拟响应验证的字段：`AT+CGPADDR`（权威 IPv4）、`AT+GTDNS`（运营商 DNS）、`AT+GTCCINFO`（小区与信号）、`AT+CESQ`（SS-RSRP/SS-RSRQ/SS-SINR）、`AT+GTCAINFO`（载波聚合）。r44 生产验证已确认真实 CGPADDR/GTDNS 响应、成功自动拨号和双栈联网，其余字段仍需更多真实样本验证。
- 厂商私有调用仅用于取信息：DNS 查询失败使用公共兜底；小区、信号与 CA 查询失败清除对应快照并显示不可用，合法但未完全解析的响应保留原始回显。
- 待完整硬件演练：USB 重枚举后的恢复、数据面假死、运营商侧 IPv6 恢复及长时间稳定性。单次生产拨号与联网成功不能替代这些演练，见 [docs/maintenance.md](docs/maintenance.md)。

## 常见问题

| 现象 | 处理 |
|---|---|
| 概览显示「模块离线」 | 检查 USB 供电与线缆；`sh /usr/lib/fm350/fm350.sh check` 查看发现结果 |
| 页面全空、状态一直不变 | rpcd 未加载后端：`/etc/init.d/rpcd restart` |
| 部署后仍是旧界面或页面报错 | 本固件的 LuCI 静态 JS 不带 Cache-Control，浏览器会继续用旧副本：强制刷新一次（Ctrl+Shift+R），或在开发者工具里勾选 Disable cache 后刷新 |
| kmod 装不上 / ABI 报错 | 离线目录的 `META` 与固件内核不一致，按 [docs/maintenance.md](docs/maintenance.md) 重抓对应版本 |
| 取主包失败（GitHub 不可达） | `FM350_RELEASE_BASE=<镜像前缀>` 换源；或在构建机自编后拷入离线目录并用 `FM350_LOCAL_APP=1` 放行 |
| Git Bash 报 `curl: (35) CRYPT_E_REVOCATION_OFFLINE` | `FM350_CURL_OPTS=--ssl-no-revoke sh download.sh`，或改用 `download.ps1` |
| 想确认配置是否生效 | `sh /usr/lib/fm350/fm350.sh check`；事件与运行日志见「日志」页 |
| 状态显示「网络接口配置」 | 查看事件中的接口冲突或配置失败原因，使用不与现有用户配置冲突的接口名；纠正后下一轮恢复管理 |

## 文档

- [docs/architecture.md](docs/architecture.md)：组件分层、主循环、状态机、恢复阶梯、拨号时序、UI 数据流、日志治理。
- [docs/maintenance.md](docs/maintenance.md)：构建、离线目录与清单、安装、升级与发布、测试与排障。
- [tests/README.md](tests/README.md)：各测试脚本的覆盖面与运行方式。

## 许可

GPL-3.0-only。
