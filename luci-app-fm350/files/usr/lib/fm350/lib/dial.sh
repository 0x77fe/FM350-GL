# 拨号/接口管理（执行现网已验证的 rndis 序列，单 owner 调用）

fs_firewall()
{
	local ifname="$1" zone
	zone=$(uci show firewall 2>/dev/null | grep "name='wan'" | head -1 | cut -d. -f2)
	[ -n "$zone" ] || return 0
	uci -q get firewall.${zone}.network 2>/dev/null | grep -qw "$ifname" || {
		uci add_list firewall.${zone}.network="$ifname" || return 1
		uci commit firewall || return 1
	}
}

# fm350_interface_exists <name>：配置存在时返回 0。
fm350_interface_exists()
{
	[ "$(uci -q get "network.$1" 2>/dev/null)" = "interface" ]
}

# 旧版本没有归属记录时，只接管完整匹配 FM350 拓扑的配置；仅有同名 section 不足以接管。
fm350_legacy_v4_shape()
{
	local name="$1" ifname="$2"
	[ "$(uci -q get "network.${name}" 2>/dev/null)" = "interface" ] \
		&& [ "$(uci -q get "network.${name}.proto" 2>/dev/null)" = "static" ] \
		&& [ "$(uci -q get "network.${name}.device" 2>/dev/null)" = "$ifname" ] \
		&& [ "$(uci -q get "network.${name}.ifname" 2>/dev/null)" = "$ifname" ] \
		&& [ "$(uci -q get "network.${name}.peerdns" 2>/dev/null)" = "0" ]
}

fm350_legacy_v6_shape()
{
	local name="$1" ifname="$2" v4="$3" dev
	[ "$(uci -q get "network.${name}" 2>/dev/null)" = "interface" ] \
		&& [ "$(uci -q get "network.${name}.proto" 2>/dev/null)" = "dhcpv6" ] \
		&& [ "$(uci -q get "network.${name}.extendprefix" 2>/dev/null)" = "1" ] || return 1
	dev=$(uci -q get "network.${name}.device" 2>/dev/null)
	[ "$(uci -q get "network.${name}.ifname" 2>/dev/null)" = "$dev" ] || return 1
	[ "$dev" = "$ifname" ] || [ "$dev" = "@${v4}" ]
}

fs_firewall_remove()
{
	local ifname="$1" zone networks
	[ -n "$ifname" ] || return 0
	zone=$(uci show firewall 2>/dev/null | grep "name='wan'" | head -1 | cut -d. -f2)
	[ -n "$zone" ] || return 0
	networks=$(uci -q get "firewall.${zone}.network" 2>/dev/null)
	echo "$networks" | tr ' ' '\n' | grep -Fxq "$ifname" || return 0
	uci -q del_list "firewall.${zone}.network=${ifname}" || return 1
	uci commit firewall || return 1
}

# dial_ensure_interfaces <ifname>：按持久归属记录迁移并幂等建立 netifd 接口。
dial_ensure_interfaces()
{
	local ifname="$1" v4 v6 v6dev managed_v4 managed_v6
	local v4_exists v6_exists v4_type v6_type v4_changed v6_changed net_changed old
	v4=$(fcfg global v4_ifname)
	v6=$(fcfg global v6_ifname)
	managed_v4=$(fcfg global managed_v4_ifname)
	managed_v6=$(fcfg global managed_v6_ifname)
	if [ "$(fcfg global v6_alias)" = "1" ]; then
		v6dev="@${v4}"
	else
		v6dev="$ifname"
	fi
	[ "$v4" != "$v6" ] || { event "接口配置冲突：IPv4 与 IPv6 接口名相同 (${v4})"; return 1; }

	v4_exists=0; v6_exists=0
	v4_type=$(uci -q get "network.${v4}" 2>/dev/null)
	v6_type=$(uci -q get "network.${v6}" 2>/dev/null)
	[ -z "$v4_type" ] || v4_exists=1
	[ -z "$v6_type" ] || v6_exists=1
	if { [ "$v4_exists" = "1" ] && [ "$v4_type" != "interface" ]; } \
		|| { [ "$v6_exists" = "1" ] && [ "$v6_type" != "interface" ]; }; then
		event "接口配置冲突：目标名称已被非 interface section 使用，未修改 network 配置"
		return 1
	fi
	# 持久归属记录允许升级后的旧 section 被清理；无记录的旧配置只按完整拓扑谨慎识别。
	if [ "$v4_exists" = "1" ] && [ "$v4" != "$managed_v4" ] \
		&& ! fm350_legacy_v4_shape "$v4" "$ifname"; then
		event "接口配置冲突：${v4} 已存在且不属于 FM350，未修改 network 配置"
		return 1
	fi
	if [ "$v6_exists" = "1" ] && [ "$v6" != "$managed_v6" ] \
		&& ! fm350_legacy_v6_shape "$v6" "$ifname" "$v4"; then
		event "接口配置冲突：${v6} 已存在且不属于 FM350，未修改 network 配置"
		return 1
	fi

	# 没有归属记录的历史默认接口只告警，绝不凭 section 名称删除。
	if [ -z "$managed_v4" ] && [ "$DFLT_V4_IFNAME" != "$v4" ] \
		&& fm350_legacy_v4_shape "$DFLT_V4_IFNAME" "$ifname"; then
		[ "${FM350_OWNERSHIP_WARNED_V4:-0}" = "1" ] || {
			event "检测到未登记归属的历史 IPv4 接口 ${DFLT_V4_IFNAME}；请确认后手动清理"
			FM350_OWNERSHIP_WARNED_V4=1
		}
	fi
	if [ -z "$managed_v6" ] && [ "$DFLT_V6_IFNAME" != "$v6" ] \
		&& fm350_legacy_v6_shape "$DFLT_V6_IFNAME" "$ifname" "$DFLT_V4_IFNAME"; then
		[ "${FM350_OWNERSHIP_WARNED_V6:-0}" = "1" ] || {
			event "检测到未登记归属的历史 IPv6 接口 ${DFLT_V6_IFNAME}；请确认后手动清理"
			FM350_OWNERSHIP_WARNED_V6=1
		}
	fi

	# Compare the whole managed shape: IPv4 device equality alone must not hide a
	# missing IPv6 interface, stale alias, or changed proto/ifname options.
	v4_changed=0
	[ "$(uci -q get "network.${v4}" 2>/dev/null)" = "interface" ] || v4_changed=1
	[ "$(uci -q get "network.${v4}.proto" 2>/dev/null)" = "static" ] || v4_changed=1
	[ "$(uci -q get "network.${v4}.device" 2>/dev/null)" = "$ifname" ] || v4_changed=1
	[ "$(uci -q get "network.${v4}.ifname" 2>/dev/null)" = "$ifname" ] || v4_changed=1
	[ "$(uci -q get "network.${v4}.peerdns" 2>/dev/null)" = "0" ] || v4_changed=1
	v6_changed=0
	[ "$(uci -q get "network.${v6}" 2>/dev/null)" = "interface" ] || v6_changed=1
	[ "$(uci -q get "network.${v6}.proto" 2>/dev/null)" = "dhcpv6" ] || v6_changed=1
	[ "$(uci -q get "network.${v6}.device" 2>/dev/null)" = "$v6dev" ] || v6_changed=1
	[ "$(uci -q get "network.${v6}.ifname" 2>/dev/null)" = "$v6dev" ] || v6_changed=1
	[ "$(uci -q get "network.${v6}.extendprefix" 2>/dev/null)" = "1" ] || v6_changed=1
	net_changed=0
	[ "$v4_changed" = "0" ] && [ "$v6_changed" = "0" ] || net_changed=1

	# 只清理前一轮明确登记为本项目所有的 section；先停客户端，再删除 network / wan 引用。
	for old in "$managed_v4" "$managed_v6"; do
		[ -n "$old" ] || continue
		if [ "$old" = "$v4" ] || [ "$old" = "$v6" ]; then
			continue
		fi
		if fm350_interface_exists "$old"; then
			ifdown "$old" 2>/dev/null
			uci -q delete "network.${old}" || return 1
			net_changed=1
		fi
		fs_firewall_remove "$old" || return 1
	done

	# 仅在不一致时写入；与上面的旧 section 清理合并一次 network commit/reload。
	if [ "$v4_changed" = "1" ]; then
		uci set "network.${v4}=interface" || return 1
		uci set "network.${v4}.proto=static" || return 1
		uci set "network.${v4}.device=${ifname}" || return 1
		uci set "network.${v4}.ifname=${ifname}" || return 1
		uci set "network.${v4}.peerdns=0" || return 1
	fi
	if [ "$v6_changed" = "1" ]; then
		[ "$v6_exists" = "0" ] || ifdown "$v6" 2>/dev/null
		uci set "network.${v6}=interface" || return 1
		uci set "network.${v6}.proto=dhcpv6" || return 1
		uci set "network.${v6}.extendprefix=1" || return 1
		uci set "network.${v6}.device=${v6dev}" || return 1
		uci set "network.${v6}.ifname=${v6dev}" || return 1
	fi
	if [ "$net_changed" = "1" ]; then
		uci commit network || return 1
		service network reload || return 1
	fi
	fs_firewall "$v4" || return 1
	fs_firewall "$v6" || return 1
	if [ "$managed_v4" != "$v4" ] || [ "$managed_v6" != "$v6" ]; then
		uci set "fm350.global.managed_v4_ifname=${v4}" || return 1
		uci set "fm350.global.managed_v6_ifname=${v6}" || return 1
		uci commit fm350 || return 1
	fi
	return 0
}

# dial_presets <port>：广和通预设（默认关闭）
dial_presets()
{
	local port="$1"
	at_check "$port" "AT+CGPIAF=1,0,0,0" || return 1
	at_check "$port" "AT+GTAUTODHCP=1" || return 1
	at_check "$port" "AT+GTIPPASS=1,1" || return 1
	at_check "$port" "AT+GTAUTOCONNECT=1" || return 1
}

# dial_now <port>：完整拨号序列
dial_now()
{
	local port="$1" define pdp apn
	define=$(fcfg profile define_connect)
	pdp=$(fcfg profile pdp_type | tr 'a-z' 'A-Z')
	apn=$(fcfg profile apn | tr 'a-z' 'A-Z')
	at_check "$port" "AT+COPS=0,0" || return 1
	at_check "$port" "AT+CGDCONT=${define},\"${pdp}\",\"${apn}\"" || return 1
	if [ "$(fcfg profile presets_enabled)" = "1" ]; then
		dial_presets "$port" || return 1
	fi
	at_check "$port" "AT+CGACT=1,${define}" || return 1
	sleep 3
	return 0
}

# dial_stop <port>：断开拨号
dial_stop()
{
	local port="$1" define
	define=$(fcfg profile define_connect)
	DIAL_STOP_REASON=""
	if ! at_check "$port" "AT+CGACT=0,${define}"; then
		DIAL_STOP_REASON="AT+CGACT=0,${define} 失败（${AT_CHECK_REASON:-响应无效}）"
		return 1
	fi
	ifdown "$(fcfg global v4_ifname)" "$(fcfg global v6_ifname)" 2>/dev/null
	return 0
}

# refresh_v4 <port> <define> <ifname> [已取得的 IPv4]：地址变化后刷新 uci 静态地址与 DNS
refresh_v4()
{
	local port="$1" define="$2" v4="$3" known="$4" ipv4 dns1 dns2
	ipv4="${known:-$(probe_v4_at "$port" "$define")}"
	[ -z "$ipv4" ] && return 0
	dns1=$(fibocom_dns_v4 "$port" "$define" 1)
	dns2=$(fibocom_dns_v4 "$port" "$define" 2)
	uci set network.${v4}.proto='static'
	uci set network.${v4}.ipaddr="$ipv4"
	uci set network.${v4}.netmask='255.255.255.0'
	uci set network.${v4}.gateway="${ipv4%.*}.1"
	uci set network.${v4}.peerdns='0'
	uci -q del network.${v4}.dns
	uci add_list network.${v4}.dns="$dns1"
	uci add_list network.${v4}.dns="$dns2"
	uci commit network
	service network reload
	ifup "$v4"
	ifup "$(fcfg global v6_ifname)"
	return 0
}
