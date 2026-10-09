#!/bin/sh
# 旧 modem 链路迁移（luci-app-modem / ModemManager 时代）—— 在路由器上执行
# 用法: sh migrate_modem.sh [备份目录]
#   · 把旧脚本、rc 链接、热插拔脚本与 /etc/config/modem 移出运行时目录，
#     副本留在持久化备份目录（默认 /root/backup/fm350-legacy-<时间戳>），不写 /var/trash；
#   · 备份目录里写入 MANIFEST 与 rollback.sh，可原样还原；
#   · 未发现旧链路时不做任何改动，返回 0。
set -e

STAMP=$(date +%Y%m%d-%H%M%S)
B=${1:-/root/backup/fm350-legacy-$STAMP}
MAN="$B/MANIFEST"

LEGACY_PKGS="luci-i18n-modem-zh-cn luci-app-modem luci-proto-modemmanager modemmanager"
LEGACY_FILES="/etc/init.d/modem /etc/init.d/modem_watcher.sh /etc/init.d/modeminit
/usr/bin/modem_watching.sh /etc/hotplug.d/net/20-modem-net /etc/config/modem"
LEGACY_DIRS="/usr/share/modem"
LEGACY_LINKS="/etc/rc.d/S70modeminit /etc/rc.d/S70modemmanager /etc/rc.d/S90modem
/etc/rc.d/S99modem_watcher.sh /etc/rc.d/K13modem /etc/rc.d/K13modeminit /etc/rc.d/K10modem_watcher.sh"

found=0
for f in $LEGACY_FILES; do [ -e "$f" ] && found=1; done
for d in $LEGACY_DIRS; do [ -d "$d" ] && found=1; done
for l in $LEGACY_LINKS; do [ -L "$l" ] && found=1; done
for p in $LEGACY_PKGS; do
	opkg list-installed 2>/dev/null | grep -q "^$p " && found=1
done
if [ "$found" = 0 ]; then
	echo "未发现旧 modem 链路，无需迁移"
	exit 0
fi

echo "[1/4] 停止旧服务"
for s in /etc/init.d/modem_watcher.sh /etc/init.d/modem /etc/init.d/modeminit /etc/init.d/modemmanager; do
	if [ -x "$s" ]; then
		"$s" stop 2>/dev/null || true
		echo "  已停止 $s"
	fi
done

mkdir -p "$B/files"
: > "$MAN"

# backup <绝对路径>：链接只记目标，文件与目录整份复制后再移出
backup()
{
	local path="$1" rel
	[ -e "$path" ] || [ -L "$path" ] || return 0
	rel=$(echo "$path" | sed 's|^/||; s|/|__|g')
	if [ -L "$path" ]; then
		echo "$path|$rel|link|$(readlink "$path")" >> "$MAN"
		rm -f "$path"
	elif [ -d "$path" ]; then
		echo "$path|$rel|dir|" >> "$MAN"
		cp -a "$path" "$B/files/$rel"
		rm -rf "$path"
	else
		echo "$path|$rel|file|" >> "$MAN"
		cp -a "$path" "$B/files/$rel"
		rm -f "$path"
	fi
	printf '  已移出 %s\n' "$path"
}

echo "[2/4] 备份并移出旧文件（备份目录 $B）"
for l in $LEGACY_LINKS; do backup "$l"; done
for f in $LEGACY_FILES; do backup "$f"; done
for d in $LEGACY_DIRS; do backup "$d"; done

echo "[3/4] 卸载旧包"
for p in $LEGACY_PKGS; do
	if opkg list-installed 2>/dev/null | grep -q "^$p "; then
		opkg remove "$p" >/dev/null 2>&1 \
			|| opkg remove --force-depends "$p" >/dev/null 2>&1 \
			|| echo "  !! 卸载 $p 失败，请手动 opkg remove --force-depends $p"
		echo "  已卸载 $p"
	fi
done

echo "[4/4] 写入恢复脚本"
cat > "$B/rollback.sh" <<'EOF'
#!/bin/sh
# 由 migrate_modem.sh 生成：按 MANIFEST 还原被移出的旧链路文件与链接
set -e
B=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$B/MANIFEST" ] || { echo "缺少 $B/MANIFEST"; exit 1; }
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
echo "文件已还原。旧包需可用 feed 时手动重装："
echo "  opkg update && opkg install luci-app-modem luci-proto-modemmanager modemmanager"
echo "还原后建议重启： reboot"
EOF
chmod +x "$B/rollback.sh"

echo "迁移完成"
echo "  备份与清单：$B"
echo "  还原方式  ：sh $B/rollback.sh"
