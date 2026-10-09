#!/bin/sh
# FM350 管理器安装脚本 —— 在路由器上执行（ImmortalWrt 24.10 / opkg 体系）
# 用法: sh install_fm350.sh [ipk路径]
set -e
IPK=${1:-$(ls /tmp/deps-ipk/luci-app-fm350_*.ipk 2>/dev/null | head -1)}
[ -f "$IPK" ] || { echo "找不到 ipk 文件: $IPK"; exit 1; }

echo "[1/5] 安装主包（离线依赖见 dist/deps-ipk/install_all.sh）"
opkg install "$IPK"

echo "[2/5] 重启 rpcd"
/etc/init.d/rpcd restart
sleep 2

echo "[3/5] 刷新静态资源 ETag"
touch /www/luci-static/resources/view/fm350/*.js /www/luci-static/resources/fm350/*.js 2>/dev/null || true
echo "  提示：浏览器仍显示旧界面或报错时，请强制刷新一次（Ctrl+Shift+R）"

echo "[4/5] 启用并启动守护"
/etc/init.d/fm350mgr disable 2>/dev/null || true
# stop → 停顿 → start：避免 procd 对 restart 的 stop/start 竞争产生双实例记录
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr enable
/etc/init.d/fm350mgr start
sleep 8

echo "[5/5] 状态检查"
echo "procs=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r ".state,.net.v4_at,.net.v4_route" /var/run/fm350/state.json 2>/dev/null

echo "打开 LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
