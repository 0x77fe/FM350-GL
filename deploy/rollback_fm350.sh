#!/bin/sh
# FM350 管理器回滚 —— 在路由器上执行（恢复旧 luci-app-modem / ModemManager 链路）
# 用法: sh rollback_fm350.sh [迁移备份目录]
#   备份目录默认取 /root/backup/fm350-legacy-* 里最新的一个（由 migrate_modem.sh 生成）
set -e

echo "[1/5] 停止并禁用新守护"
[ -x /etc/init.d/fm350mgr ] && { /etc/init.d/fm350mgr stop 2>/dev/null || true; /etc/init.d/fm350mgr disable 2>/dev/null || true; }

echo "[2/5] 卸载新包"
opkg remove luci-app-fm350 >/dev/null 2>&1 || true

B="$1"
if [ -z "$B" ]; then
	for d in /root/backup/fm350-legacy-*; do
		[ -d "$d" ] && B="$d"
	done
fi

if [ -n "$B" ] && [ -f "$B/rollback.sh" ]; then
	echo "[3/5] 还原旧链路文件（$B）"
	sh "$B/rollback.sh"
elif [ -n "$B" ] && [ -f "$B/MANIFEST" ]; then
	echo "[3/5] 还原旧链路文件（$B，按 MANIFEST）"
	while IFS='|' read -r path rel kind target; do
		[ -n "$path" ] || continue
		mkdir -p "$(dirname "$path")"
		case "$kind" in
			link) rm -rf "$path"; ln -sf "$target" "$path" ;;
			dir)  rm -rf "$path"; mkdir -p "$path"; cp -a "$B/files/$rel/." "$path/" ;;
			*)    rm -f "$path"; cp -a "$B/files/$rel" "$path" ;;
		esac
		echo "  已还原 $path"
	done < "$B/MANIFEST"
else
	echo "[3/5] 未找到迁移备份（/root/backup/fm350-legacy-*）：跳过文件还原"
	echo "     旧版脚本的备份在 /root/backup/fm350（modem.init / modem-share 等），可手工恢复"
	OLD=/root/backup/fm350
	if [ -d "$OLD" ]; then
		[ -f "$OLD/modem.init" ] && { cp "$OLD/modem.init" /etc/init.d/modem; chmod +x /etc/init.d/modem; echo "  已还原 /etc/init.d/modem"; }
		[ -d "$OLD/modem-share" ] && { mkdir -p /usr/share/modem; cp -a "$OLD/modem-share/." /usr/share/modem/; echo "  已还原 /usr/share/modem"; }
	fi
fi

echo "[4/5] 重装旧包（需要可用 feed）"
opkg update >/dev/null 2>&1 || echo "  警告: opkg update 失败，请联网后重试"
opkg install luci-app-modem luci-proto-modemmanager modemmanager 2>/dev/null \
	|| echo "  警告: 旧包重装失败，请在可用源上手动安装"

echo "[5/5] 启动旧链路"
for s in /etc/init.d/modem /etc/init.d/modem_watcher.sh /etc/init.d/modemmanager; do
	[ -x "$s" ] && { "$s" enable 2>/dev/null || true; "$s" start 2>/dev/null || true; }
done

echo "回滚完成，建议重启： reboot"
