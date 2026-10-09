# 配置读取、集中默认值与校验
#
# 配置唯一来源是 /etc/config/fm350（包内模板 /usr/share/fm350/config.template 与其内容一致）。
# 本文件负责缺项兜底与非法值回退：类型或范围不合法时一律返回 DFLT_* 默认值，
# 使错误的配置不会让守护进入异常退出的路径。
#
# 生效时机：
#   · global / watch / notify 下各项每轮重新读取，改动下一轮生效；
#   · profile.apn / profile.pdp_type / profile.define_connect 在下次拨号（dial_now）时生效；
#   · global.v4_ifname / global.v6_ifname / global.v6_alias 改动会重建 netifd 接口；
#   · watch.frozen_enabled / ipv6_check_enabled / ca_check_enabled 立即改变检测行为。

DFLT_ENABLED="1"
DFLT_INTERVAL="5"
DFLT_AT_PORT=""
DFLT_USB_VID_PID=""
DFLT_USB_PATH_HINT=""
DFLT_V4_IFNAME="wwan_5g_0"
DFLT_V6_IFNAME="wwan6_5g_0"
DFLT_V6_ALIAS="1"
DFLT_WAIT_TIMEOUT="180"
DFLT_RECOVERY_TIMEOUT="300"
DFLT_USB_RESET_TIMEOUT="600"
DFLT_RESTART_TIMEOUT="1800"
DFLT_COOLDOWN="300"
DFLT_USB_RESET_ENABLED="1"
DFLT_FROZEN_ENABLED="1"
DFLT_FROZEN_SAMPLE="30"
DFLT_FROZEN_GRACE="120"
DFLT_IPV6_CHECK_ENABLED="1"
DFLT_IPV6_PING_TARGET="2400:3200::1"
DFLT_IPV6_PING_INTERVAL="15"
DFLT_IPV4_PING_TARGET="202.101.224.69"
DFLT_CA_CHECK_ENABLED="1"
DFLT_CA_INTERVAL="120"
DFLT_IPV6_ESCALATE="1"
DFLT_REAPPEAR_TIMEOUT="300"
DFLT_PROFILE_ENABLE="1"
DFLT_APN="ctnet"
DFLT_PDP_TYPE="ipv4v6"
DFLT_DEFINE_CONNECT="3"
DFLT_PRESETS_ENABLED="0"
DFLT_EVENTS_KEEP="200"

# 本轮配置缓存：load_config 每轮读取一次 uci，fcfg 走纯 shell 查表
CFG_LOADED=""
CFG_RAW=""

# load_config：把 uci 配置压成 "|section.option=value|…" 供 fcfg 查表
load_config()
{
	local line rest sec opt val

	CFG_RAW=""
	CFG_LOADED=1
	sec=""
	while IFS= read -r line; do
		case "$line" in
			"config fm350 '"*)
				rest=${line#*\'}
				sec=${rest%%\'*}
			;;
			*"option "*"'"*)
				[ -n "$sec" ] || continue
				rest=${line#*option }
				opt=${rest%% *}
				val=${rest#*\'}
				val=${val%%\'*}
				case "$opt" in
					''|*[!a-z0-9_]*) continue ;;
				esac
				case "$val" in
					*"|"*) continue ;;
				esac
				CFG_RAW="${CFG_RAW}|${sec}.${opt}=${val}"
			;;
		esac
	done <<EOF
$(uci -q export fm350 2>/dev/null)
EOF
}

# cfg_raw <section> <option>：取原始值；未加载缓存时直接查 uci
cfg_raw()
{
	local rest

	if [ -z "$CFG_LOADED" ]; then
		uci -q get "fm350.$1.$2"
		return
	fi
	case "$CFG_RAW" in
		*"|$1.$2="*)
			rest=${CFG_RAW#*"|$1.$2="}
			echo "${rest%%|*}"
		;;
		*) echo "" ;;
	esac
}

# cfg_bool <值> <默认值>
cfg_bool()
{
	case "$1" in
		0|1) echo "$1" ;;
		*) echo "$2" ;;
	esac
}

# cfg_num <值> <默认值> <最小值> <最大值>
cfg_num()
{
	case "$1" in
		''|*[!0-9]*) echo "$2" ;;
		*)
			if [ "$1" -ge "$3" ] && [ "$1" -le "$4" ]; then
				echo "$1"
			else
				echo "$2"
			fi
		;;
	esac
}

# cfg_enum <值> <默认值> <候选值，逗号分隔>
cfg_enum()
{
	case ",$3," in
		*",$1,"*) echo "$1" ;;
		*) echo "$2" ;;
	esac
}

# cfg_ifname <值> <默认值>：netifd 接口名
cfg_ifname()
{
	case "$1" in
		''|*[!A-Za-z0-9._-]*) echo "$2" ;;
		*)
			if [ ${#1} -le 15 ]; then echo "$1"; else echo "$2"; fi
		;;
	esac
}

# cfg_dev <值> <默认值>：设备路径与 USB 路径提示
cfg_dev()
{
	case "$1" in
		''|*[!A-Za-z0-9/._:-]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

# cfg_host <值> <默认值>：探测目标（IPv4/IPv6 字面量或域名）
cfg_host()
{
	case "$1" in
		''|*[!A-Za-z0-9:._-]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

# cfg_vidpid <值> <默认值>：VID:PID，留空表示自动识别
cfg_vidpid()
{
	case "$1" in
		'') echo "" ;;
		*[!A-Fa-f0-9:]*) echo "$2" ;;
		*:*:*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

# cfg_apn <值> <默认值>
cfg_apn()
{
	case "$1" in
		''|*[!A-Za-z0-9._-]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

# fcfg <section> <option>：读取 uci fm350，校验后返回，非法或缺失时用集中默认值
fcfg()
{
	local v

	v=$(cfg_raw "$1" "$2")
	case "$1.$2" in
		global.enabled) cfg_bool "$v" "$DFLT_ENABLED" ;;
		global.interval) cfg_num "$v" "$DFLT_INTERVAL" 2 3600 ;;
		global.at_port) cfg_dev "$v" "$DFLT_AT_PORT" ;;
		global.usb_vid_pid) cfg_vidpid "$v" "$DFLT_USB_VID_PID" ;;
		global.usb_path_hint) cfg_dev "$v" "$DFLT_USB_PATH_HINT" ;;
		global.v4_ifname) cfg_ifname "$v" "$DFLT_V4_IFNAME" ;;
		global.v6_ifname) cfg_ifname "$v" "$DFLT_V6_IFNAME" ;;
		global.v6_alias) cfg_bool "$v" "$DFLT_V6_ALIAS" ;;
		watch.wait_timeout) cfg_num "$v" "$DFLT_WAIT_TIMEOUT" 30 86400 ;;
		watch.recovery_timeout) cfg_num "$v" "$DFLT_RECOVERY_TIMEOUT" 30 86400 ;;
		watch.usb_reset_timeout) cfg_num "$v" "$DFLT_USB_RESET_TIMEOUT" 60 604800 ;;
		watch.restart_timeout) cfg_num "$v" "$DFLT_RESTART_TIMEOUT" 60 604800 ;;
		watch.cooldown) cfg_num "$v" "$DFLT_COOLDOWN" 30 86400 ;;
		watch.usb_reset_enabled) cfg_bool "$v" "$DFLT_USB_RESET_ENABLED" ;;
		watch.frozen_enabled) cfg_bool "$v" "$DFLT_FROZEN_ENABLED" ;;
		watch.frozen_sample) cfg_num "$v" "$DFLT_FROZEN_SAMPLE" 10 3600 ;;
		watch.frozen_grace) cfg_num "$v" "$DFLT_FROZEN_GRACE" 0 86400 ;;
		watch.ipv6_check_enabled) cfg_bool "$v" "$DFLT_IPV6_CHECK_ENABLED" ;;
		watch.ipv6_ping_target) cfg_host "$v" "$DFLT_IPV6_PING_TARGET" ;;
		watch.ipv6_ping_interval) cfg_num "$v" "$DFLT_IPV6_PING_INTERVAL" 5 3600 ;;
		watch.ipv4_ping_target) cfg_host "$v" "$DFLT_IPV4_PING_TARGET" ;;
		watch.ca_check_enabled) cfg_bool "$v" "$DFLT_CA_CHECK_ENABLED" ;;
		watch.ca_interval) cfg_num "$v" "$DFLT_CA_INTERVAL" 30 86400 ;;
		watch.ipv6_escalate) cfg_bool "$v" "$DFLT_IPV6_ESCALATE" ;;
		watch.reappear_timeout) cfg_num "$v" "$DFLT_REAPPEAR_TIMEOUT" 30 604800 ;;
		profile.enable) cfg_bool "$v" "$DFLT_PROFILE_ENABLE" ;;
		profile.apn) cfg_apn "$v" "$DFLT_APN" ;;
		profile.pdp_type) cfg_enum "$v" "$DFLT_PDP_TYPE" "ipv4,ipv6,ipv4v6" ;;
		profile.define_connect) cfg_num "$v" "$DFLT_DEFINE_CONNECT" 1 15 ;;
		profile.presets_enabled) cfg_bool "$v" "$DFLT_PRESETS_ENABLED" ;;
		notify.events_keep) cfg_num "$v" "$DFLT_EVENTS_KEEP" 20 10000 ;;
		*) echo "$v" ;;
	esac
}
