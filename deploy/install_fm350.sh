#!/bin/sh
# FM350 管理器安装脚本 v2 —— 在路由器(<router>)上执行
# 用法: sh install_fm350.sh [ipk路径]
# 说明: 旧包完整卸载顺序修复版（先卸 i18n 语言包，否则 luci-app-modem 拒删；
#       modemmanager 对依赖警告需 --force-depends）
set -e
IPK=${1:-$(ls /tmp/deps-ipk/luci-app-fm350_*.ipk 2>/dev/null | head -1)}
[ -f "$IPK" ] || { echo "找不到 ipk 文件: $IPK"; exit 1; }

BACKUP=/root/backup/fm350
mkdir -p "$BACKUP" /var/trash

echo "[1/7] 备份旧脚本到 $BACKUP..."
[ -f /etc/init.d/modem ] && cp /etc/init.d/modem "$BACKUP/modem.init"
[ -f /etc/init.d/modem_watcher.sh ] && cp /etc/init.d/modem_watcher.sh "$BACKUP/" 2>/dev/null || true
[ -f /usr/bin/modem_watching.sh ] && cp /usr/bin/modem_watching.sh "$BACKUP/" 2>/dev/null || true
[ -f /etc/hotplug.d/net/20-modem-net ] && cp /etc/hotplug.d/net/20-modem-net "$BACKUP/" 2>/dev/null || true
[ -d /usr/share/modem ] && [ ! -d "$BACKUP/modem-share" ] && cp -r /usr/share/modem "$BACKUP/modem-share" 2>/dev/null || true

echo "[2/7] 停止并禁用旧服务..."
for s in /etc/init.d/modem_watcher.sh /etc/init.d/modem /etc/init.d/modeminit /etc/init.d/modemmanager; do
	[ -x "$s" ] && { "$s" stop 2>/dev/null || true; "$s" disable 2>/dev/null || true; }
done

echo "[3/7] 卸载旧包（顺序: i18n -> app -> proto/MM force）..."
opkg remove luci-i18n-modem-zh-cn >/dev/null 2>&1 || true
opkg remove luci-app-modem >/dev/null 2>&1 || true
opkg remove --force-depends luci-proto-modemmanager modemmanager >/dev/null 2>&1 || true

echo "[4/7] 清理旧 rc 链接与遗留文件（mv 到 /var/trash）..."
for l in /etc/rc.d/S70modeminit /etc/rc.d/S70modemmanager /etc/rc.d/S90modem /etc/rc.d/S99modem_watcher.sh \
	 /etc/rc.d/K13modem /etc/rc.d/K13modeminit /etc/rc.d/K10modem_watcher.sh; do
	[ -L "$l" ] && mv "$l" /var/trash/ 2>/dev/null || true
done
[ -f /etc/init.d/modem_watcher.sh ] && mv /etc/init.d/modem_watcher.sh /var/trash/ 2>/dev/null || true
[ -f /usr/bin/modem_watching.sh ] && mv /usr/bin/modem_watching.sh /var/trash/ 2>/dev/null || true
[ -d /usr/share/modem ] && mv /usr/share/modem /var/trash/modem-us-share 2>/dev/null || true
[ -f /etc/hotplug.d/net/20-modem-net ] && mv /etc/hotplug.d/net/20-modem-net /var/trash/ 2>/dev/null || true
[ -f /etc/config/modem ] && mv /etc/config/modem /var/trash/config-modem.bak 2>/dev/null || true
for l in $(ls /etc/rc.d/ 2>/dev/null | grep -E "K1[03]modem|S9[09]modem" 2>/dev/null); do
	[ -L "/etc/rc.d/$l" ] && mv "/etc/rc.d/$l" /var/trash/ 2>/dev/null || true
done

echo "[5/7] 安装依赖与主包（离线包: dist/deps-ipk/install_all.sh）..."
opkg install "$IPK"

echo "[6/7] 启用并启动..."
/etc/init.d/rpcd restart
sleep 2
# 静态资源走"每次请求重新验证"，避免浏览器启发式缓存旧版 JS
uci -q get uhttpd.main.no_cache | grep -q js || { uci set uhttpd.main.no_cache='js'; uci commit uhttpd; }
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
touch /www/luci-static/resources/view/fm350/*.js 2>/dev/null || true
/etc/init.d/fm350mgr enable
# stop -> 停顿 -> start：避免 procd 对 restart 的 stop/start 竞争产生双实例记录
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr start
sleep 8

echo "[7/7] 状态检查..."
echo "procs=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r ".state,.net.v4_at,.net.v4_route" /var/run/fm350/state.json 2>/dev/null
echo "-------- 完成 --------"
echo "打开 LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
