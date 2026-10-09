#!/bin/sh
# FM350 管理器安装脚本（OpenWrt 25.12 及以后 · apk 体系）—— 在路由器上执行
# 用法: sh install_fm350_apk.sh [/tmp/luci-app-fm350-<ver>.apk]
#
# 与 deploy/install_fm350.sh（ImmortalWrt 24.10 · opkg 版）的区别：
#   1. 25.12 起包管理器是 apk；自行构建的包没进官方密钥，必须 --allow-untrusted；
#   2. 官方 x86/64 镜像不含任何 kmod-usb-*，USB 主机控制器与 RNDIS/串口驱动都要现装；
#      kmod 必须与固件内核同 ABI，装错版本 apk 直接拒绝（故不把 kmod 写进包依赖）；
#
# 路由器不联网时用离线包（kmod/jq/sms-tool 全在包里，apk 走 --network=no）。
# 先在联网机器上跑 dist/deps-apk 的 download.sh 或 download.ps1 把依赖下齐，再整包传到路由器安装。
set -e

APK=${1:-$(ls /tmp/luci-app-fm350-*.apk 2>/dev/null | head -1)}
[ -f "$APK" ] || { echo "找不到 apk 文件: $APK"; exit 1; }
command -v apk >/dev/null 2>&1 || { echo "本固件不是 apk 体系（apk 从 OpenWrt 25.12 开始）"; exit 1; }

echo "[1/6] 安装 USB 依赖（kmod 需联网、需与固件内核 ABI 同版）..."
# 主机控制器：x86 常见 xhci/ehci/ohci；usb-net-* 出 RNDIS/ECM 网卡；usb-serial-* 出 AT 口
apk -U add \
	kmod-usb-core kmod-usb2 kmod-usb3 \
	kmod-usb-xhci-hcd kmod-usb-ehci kmod-usb-ohci \
	kmod-usb-net kmod-usb-net-cdc-ether kmod-usb-net-rndis \
	kmod-usb-serial kmod-usb-serial-wwan kmod-usb-acm kmod-usb-wdm

echo "[2/6] 安装主包（jq / sms-tool 作为依赖自动从官方源拉取）..."
apk add --allow-untrusted "$APK"

echo "[3/6] 重启 rpcd（否则 ubus 对象 fm350 不注册，页面全空）..."
/etc/init.d/rpcd restart
sleep 2

echo "[4/6] 刷新静态资源 ETag..."
touch /www/luci-static/resources/view/fm350/*.js /www/luci-static/resources/fm350/*.js 2>/dev/null || true
echo "  提示：浏览器仍显示旧界面或报错时，请强制刷新一次（Ctrl+Shift+R）"

echo "[5/6] 启用并启动守护..."
/etc/init.d/fm350mgr enable
# stop → 停顿 → start：procd 对 restart 的 stop/start 竞争会产生双实例记录
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr start
sleep 8

echo "[6/6] 状态检查..."
echo "procs=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r ".state,.net.v4_at,.net.v4_route" /var/run/fm350/state.json 2>/dev/null || echo "(state.json 未生成：logread | grep fm350 查看原因)"
apk list -I 2>/dev/null | grep -i fm350 || echo "(未出现在 apk list -I 中！)"
echo "-------- 完成 --------"
echo "打开 LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
