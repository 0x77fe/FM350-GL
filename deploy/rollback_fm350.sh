#!/bin/sh
# FM350 管理器回滚脚本 —— 在路由器上执行（恢复旧 luci-app-modem 链路）
# 前提：/root/backup/fm350 存在（install_fm350.sh 已做备份），且路由器可访问 opkg feed
set -e

echo "[1/5] 停止并禁用新守护..."
[ -x /etc/init.d/fm350mgr ] && { /etc/init.d/fm350mgr stop 2>/dev/null || true; /etc/init.d/fm350mgr disable 2>/dev/null || true; }

echo "[2/5] 卸载新包..."
opkg remove luci-app-fm350 >/dev/null 2>&1 || true

B=/root/backup/fm350
if [ -d "$B" ]; then
	echo "[3/5] 恢复备份文件..."
	mkdir -p /usr/share/modem /var/trash
	[ -d "$B/modem-share" ] && mv /usr/share/modem /var/trash/modem-us-empty 2>/dev/null || true
	[ -d "$B/modem-share" ] && cp -r "$B/modem-share" /usr/share/modem || true
	[ -f "$B/modem.init" ] && { cp "$B/modem.init" /etc/init.d/modem; chmod +x /etc/init.d/modem; }
	[ -f "$B/modem_watcher.sh" ] && { cp "$B/modem_watcher.sh" /etc/init.d/modem_watcher.sh; chmod +x /etc/init.d/modem_watcher.sh; }
	[ -f "$B/modem_watching.sh" ] && { cp "$B/modem_watching.sh" /usr/bin/modem_watching.sh; chmod +x /usr/bin/modem_watching.sh; }
	[ -f "$B/20-modem-net" ] && cp "$B/20-modem-net" /etc/hotplug.d/net/20-modem-net
else
	echo "[3/5] 无备份目录 $B，跳过文件恢复"
fi

echo "[4/5] 重装旧包（若源 feed 可用）..."
opkg install luci-app-modem luci-proto-modemmanager modemmanager 2>/dev/null || echo "警告: 旧包重装失败，请手动 opkg update 后重试"

echo "[5/5] 启动旧链路..."
[ -x /etc/init.d/modem ] && { /etc/init.d/modem enable || true; /etc/init.d/modem start || true; }
[ -x /etc/init.d/modem_watcher.sh ] && { /etc/init.d/modem_watcher.sh enable || true; /etc/init.d/modem_watcher.sh start || true; }

echo "回滚完成"
