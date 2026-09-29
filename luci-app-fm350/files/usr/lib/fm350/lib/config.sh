# 配置读取与集中默认值
DFLT_ENABLED="1"
DFLT_INTERVAL="5"
DFLT_AT_PORT=""
DFLT_USB_VID_PID=""
DFLT_USB_PATH_HINT=""
DFLT_NETIF_WAIT="15"
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

# fcfg <section> <option>：读取 uci fm350，缺失时返回集中默认值
fcfg()
{
	local v
	v=$(uci -q get "fm350.$1.$2")
	[ -n "$v" ] && { echo "$v"; return; }
	case "$1.$2" in
		global.enabled) echo "$DFLT_ENABLED" ;;
		global.interval) echo "$DFLT_INTERVAL" ;;
		global.at_port) echo "$DFLT_AT_PORT" ;;
		global.usb_vid_pid) echo "$DFLT_USB_VID_PID" ;;
		global.usb_path_hint) echo "$DFLT_USB_PATH_HINT" ;;
		global.netif_wait) echo "$DFLT_NETIF_WAIT" ;;
		global.v4_ifname) echo "$DFLT_V4_IFNAME" ;;
		global.v6_ifname) echo "$DFLT_V6_IFNAME" ;;
		global.v6_alias) echo "$DFLT_V6_ALIAS" ;;
		watch.wait_timeout) echo "$DFLT_WAIT_TIMEOUT" ;;
		watch.recovery_timeout) echo "$DFLT_RECOVERY_TIMEOUT" ;;
		watch.usb_reset_timeout) echo "$DFLT_USB_RESET_TIMEOUT" ;;
		watch.restart_timeout) echo "$DFLT_RESTART_TIMEOUT" ;;
		watch.cooldown) echo "$DFLT_COOLDOWN" ;;
		watch.usb_reset_enabled) echo "$DFLT_USB_RESET_ENABLED" ;;
		watch.frozen_enabled) echo "$DFLT_FROZEN_ENABLED" ;;
		watch.frozen_sample) echo "$DFLT_FROZEN_SAMPLE" ;;
		watch.frozen_grace) echo "$DFLT_FROZEN_GRACE" ;;
		watch.ipv6_check_enabled) echo "$DFLT_IPV6_CHECK_ENABLED" ;;
		watch.ipv6_ping_target) echo "$DFLT_IPV6_PING_TARGET" ;;
		watch.ipv6_ping_interval) echo "$DFLT_IPV6_PING_INTERVAL" ;;
		watch.ipv4_ping_target) echo "$DFLT_IPV4_PING_TARGET" ;;
		watch.ca_check_enabled) echo "$DFLT_CA_CHECK_ENABLED" ;;
		watch.ca_interval) echo "$DFLT_CA_INTERVAL" ;;
		watch.ipv6_escalate) echo "$DFLT_IPV6_ESCALATE" ;;
		watch.reappear_timeout) echo "$DFLT_REAPPEAR_TIMEOUT" ;;
		profile.enable) echo "$DFLT_PROFILE_ENABLE" ;;
		profile.apn) echo "$DFLT_APN" ;;
		profile.pdp_type) echo "$DFLT_PDP_TYPE" ;;
		profile.define_connect) echo "$DFLT_DEFINE_CONNECT" ;;
		profile.presets_enabled) echo "$DFLT_PRESETS_ENABLED" ;;
		notify.events_keep) echo "$DFLT_EVENTS_KEEP" ;;
		*) echo "" ;;
	esac
}
