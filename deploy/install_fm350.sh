#!/bin/sh
# FM350 管理器安装脚本 —— 在路由器上执行（ImmortalWrt 24.10 / opkg 体系）
# 用法: sh install_fm350.sh [ipk路径]
#
# 旧 modem 链路（luci-app-modem / ModemManager）迁移由同目录的 migrate_modem.sh 单独负责：
#   · 默认自动调用（找不到遗留时它不做任何改动）；
#   · FM350_SKIP_MIGRATE=1 可跳过；FM350_MIGRATE_BACKUP=<目录> 可指定备份位置；
#   · 迁移会留下持久备份与 rollback.sh，不依赖 /var/trash。
set -e
IPK=${1:-$(ls /tmp/deps-ipk/luci-app-fm350_*.ipk 2>/dev/null | head -1)}
[ -f "$IPK" ] || { echo "找不到 ipk 文件: $IPK"; exit 1; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MIGRATE="${FM350_MIGRATE:-$HERE/migrate_modem.sh}"

echo "[1/6] 旧 modem 链路迁移"
if [ -n "$FM350_SKIP_MIGRATE" ]; then
	echo "  已按 FM350_SKIP_MIGRATE 跳过（本机若有旧链路残留，需自行处理）"
elif [ -f "$MIGRATE" ]; then
	sh "$MIGRATE" ${FM350_MIGRATE_BACKUP:+"$FM350_MIGRATE_BACKUP"}
else
	echo "  !! 找不到迁移脚本 $MIGRATE"
	echo "     本机若有 luci-app-modem / ModemManager 遗留，请先单独执行迁移脚本，或用 FM350_SKIP_MIGRATE=1 明确跳过"
	exit 1
fi

echo "[2/6] 安装主包（离线依赖见 dist/deps-ipk/install_all.sh）"
opkg install "$IPK"

echo "[3/6] 重启 rpcd 与 uhttpd"
/etc/init.d/rpcd restart
sleep 2
# 静态资源走"每次请求重新验证"，避免浏览器启发式缓存旧版 JS
uci -q get uhttpd.main.no_cache | grep -q js || { uci set uhttpd.main.no_cache='js'; uci commit uhttpd; }
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
touch /www/luci-static/resources/view/fm350/*.js /www/luci-static/resources/fm350/*.js 2>/dev/null || true

echo "[4/6] 启用并启动守护"
/etc/init.d/fm350mgr disable 2>/dev/null || true
# stop → 停顿 → start：避免 procd 对 restart 的 stop/start 竞争产生双实例记录
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr enable
/etc/init.d/fm350mgr start
sleep 8

echo "[5/6] 状态检查"
echo "procs=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r ".state,.net.v4_at,.net.v4_route" /var/run/fm350/state.json 2>/dev/null

echo "[6/6] 完成"
echo "打开 LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
