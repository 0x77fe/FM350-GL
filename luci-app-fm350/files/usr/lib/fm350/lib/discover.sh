# 模块自动发现：不依赖固定 USB 路径，按 VID:PID 全局扫描
# 输出全局：D_VID D_PID D_USB_PATH D_DEVNODE D_IFNAME D_AT_PORT D_USB_COUNT

discover_scan()
{
	local vid_pid vid pid d v p count dev bus devn
	vid_pid=$(fcfg global usb_vid_pid)
	if [ -z "$vid_pid" ]; then
		# 自动识别模式（配置留空）：按串口 AT 应答定位模组，无需预知 VID:PID
		discover_auto
		return $?
	fi
	vid=$(echo "$vid_pid" | cut -d: -f1)
	pid=$(echo "$vid_pid" | cut -d: -f2)
	[ -n "$vid" ] || vid="0e8d"
	[ -n "$pid" ] || pid="7127"

	D_USB_PATH=""
	D_USB_COUNT=0
	for d in /sys/bus/usb/devices/*/; do
		[ -f "${d}idVendor" ] || continue
		v=$(cat "${d}idVendor")
		p=$(cat "${d}idProduct")
		if [ "$v" = "$vid" ] && [ "$p" = "$pid" ]; then
			D_USB_COUNT=$((D_USB_COUNT + 1))
			[ -z "$D_USB_PATH" ] && D_USB_PATH=$(basename "$d")
		fi
	done

	D_VID="$vid"
	D_PID="$pid"
	if [ -z "$D_USB_PATH" ]; then
		D_IFNAME=""
		D_AT_PORT=""
		D_DEVNODE=""
		return 1
	fi

	# 设备节点（usbreset 用）：busnum/devnum 而非 dev 的 major:minor
	bus=$(cat "/sys/bus/usb/devices/${D_USB_PATH}/busnum" 2>/dev/null)
	devn=$(cat "/sys/bus/usb/devices/${D_USB_PATH}/devnum" 2>/dev/null)
	D_DEVNODE=""
	[ -n "$bus" ] && [ -n "$devn" ] && D_DEVNODE=$(printf "/dev/bus/usb/%03d/%03d" "$bus" "$devn")

	discover_ifname
	discover_at_port ""
	return 0
}

# 自动识别模组（usb_vid_pid 留空时）：遍历 USB 设备（排除 hub），
# 对其串口探测 AT 应答（FM350/Fibocom/Manufacturer 特征），命中即模组；
# 结果（VID:PID/path/AT口）由上游写入 state 缓存
discover_auto()
{
	local d v p path tty bus devn last
	last=$(cat "${RU}/at_probe.last" 2>/dev/null)
	[ -n "$last" ] && [ "$(( $(date +%s) - last ))" -lt 60 ] && return 1
	for d in /sys/bus/usb/devices/*/; do
		[ -f "${d}idVendor" ] || continue
		[ "$(cat "${d}bDeviceClass" 2>/dev/null)" = "09" ] && continue
		for tty in "${d}"*:*/ttyUSB*; do
			[ -e "$tty" ] || continue
			at_probe_port "/dev/$(basename "$tty")" || continue
			path=$(basename "$d")
			v=$(cat "${d}idVendor")
			p=$(cat "${d}idProduct")
			D_USB_PATH="$path"
			D_VID="$v"
			D_PID="$p"
			D_USB_COUNT=1
			bus=$(cat "${d}busnum" 2>/dev/null)
			devn=$(cat "${d}devnum" 2>/dev/null)
			D_DEVNODE=""
			[ -n "$bus" ] && [ -n "$devn" ] && D_DEVNODE=$(printf "/dev/bus/usb/%03d/%03d" "$bus" "$devn")
			discover_ifname
			D_AT_PORT="/dev/$(basename "$tty")"
			date +%s > "${RU}/at_probe.last"
			return 0
		done
	done
	D_USB_PATH=""
	D_IFNAME=""
	D_AT_PORT=""
	date +%s > "${RU}/at_probe.last"
	return 1
}

# 网卡推导：RNDIS host 接口位于设备路径下的 interface/net/*
discover_ifname()
{
	local n ifn
	D_IFNAME=""
	for n in /sys/bus/usb/devices/${D_USB_PATH}/*/net/*; do
		[ -e "$n" ] || continue
		D_IFNAME=$(basename "$n")
		return 0
	done
	# 回退：/sys/class/net 反查 device 路径
	for n in /sys/class/net/*; do
		[ -e "$n/device" ] || continue
		ifn=$(readlink -f "$n/device")
		case "$ifn" in
			*"/${D_USB_PATH}"/*|*"/${D_USB_PATH}:"*)
				D_IFNAME=$(basename "$n")
				return 0
			;;
		esac
	done
	return 0
}

# AT 口探测：配置文件优先，失败则遍历 ttyUSB；全量探测带 60s 冷却（避免每轮全扫 8 口）
discover_at_port()
{
	local cfg t last
	cfg="$1"
	[ -n "$cfg" ] && [ -e "$cfg" ] && at_probe_port "$cfg" && {
		D_AT_PORT="$cfg"
		date +%s > "${RU}/at_probe.last"
		return 0
	}
	last=$(cat "${RU}/at_probe.last" 2>/dev/null)
	[ -n "$last" ] && [ "$(( $(date +%s) - last ))" -lt 60 ] && return 1
	for t in /dev/ttyUSB*; do
		[ -e "$t" ] || continue
		at_probe_port "$t" && {
			D_AT_PORT="$t"
			date +%s > "${RU}/at_probe.last"
			return 0
		}
	done
	D_AT_PORT=""
	date +%s > "${RU}/at_probe.last"
	return 1
}

# discover_light：仅在有缓存路径时做廉价检查（idVendor），失效才全扫
discover_light()
{
	local v bus devn
	if [ -n "$D_USB_PATH" ] && [ -f "/sys/bus/usb/devices/${D_USB_PATH}/idVendor" ]; then
		v=$(cat "/sys/bus/usb/devices/${D_USB_PATH}/idVendor")
		[ "$v" = "$D_VID" ] || { discover_scan; return $?; }
		# 重枚举后设备节点会变化，重算 devnode
		bus=$(cat "/sys/bus/usb/devices/${D_USB_PATH}/busnum" 2>/dev/null)
		devn=$(cat "/sys/bus/usb/devices/${D_USB_PATH}/devnum" 2>/dev/null)
		D_DEVNODE=""
		[ -n "$bus" ] && [ -n "$devn" ] && D_DEVNODE=$(printf "/dev/bus/usb/%03d/%03d" "$bus" "$devn")
		return 0
	fi
	discover_scan
}
