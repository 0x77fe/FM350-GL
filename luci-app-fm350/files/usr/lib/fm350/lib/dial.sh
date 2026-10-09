# 拨号/接口管理（执行现网已验证的 rndis 序列，单 owner 调用）

fs_firewall()
{
	local ifname="$1" zone
	zone=$(uci show firewall 2>/dev/null | grep "name='wan'" | head -1 | cut -d. -f2)
	[ -n "$zone" ] || return 0
	uci -q get firewall.${zone}.network 2>/dev/null | grep -qw "$ifname" || {
		uci add_list firewall.${zone}.network="$ifname"
		uci commit firewall
	}
}

# dial_ensure_interfaces <ifname>：幂等建立 netifd 接口（网卡名变化时重建）
dial_ensure_interfaces()
{
	local ifname="$1" v4 v6 cur
	v4=$(fcfg global v4_ifname)
	v6=$(fcfg global v6_ifname)
	cur=$(uci -q get "network.${v4}.device")
	[ "$cur" = "$ifname" ] && return 0
	uci set network.${v4}='interface'
	uci set network.${v4}.proto='static'
	uci set network.${v4}.device="$ifname"
	uci set network.${v4}.ifname="$ifname"
	uci set network.${v4}.peerdns='0'
	uci set network.${v6}='interface'
	uci set network.${v6}.proto='dhcpv6'
	uci set network.${v6}.extendprefix='1'
	if [ "$(fcfg global v6_alias)" = "1" ]; then
		uci set network.${v6}.device="@${v4}"
		uci set network.${v6}.ifname="@${v4}"
	else
		uci set network.${v6}.device="$ifname"
		uci set network.${v6}.ifname="$ifname"
	fi
	uci commit network
	fs_firewall "$v4"
	fs_firewall "$v6"
	service network reload
	return 0
}

# dial_presets <port>：广和通预设（默认关闭）
dial_presets()
{
	local port="$1"
	at_run "$port" "AT+CGPIAF=1,0,0,0" >/dev/null
	at_run "$port" "AT+GTAUTODHCP=1" >/dev/null
	at_run "$port" "AT+GTIPPASS=1,1" >/dev/null
	at_run "$port" "AT+GTAUTOCONNECT=1" >/dev/null
}

# dial_now <port>：完整拨号序列
dial_now()
{
	local port="$1" define pdp apn
	define=$(fcfg profile define_connect)
	pdp=$(fcfg profile pdp_type | tr 'a-z' 'A-Z')
	apn=$(fcfg profile apn | tr 'a-z' 'A-Z')
	at_run "$port" "AT+COPS=0,0" >/dev/null
	at_run "$port" "AT+CGDCONT=${define},\"${pdp}\",\"${apn}\"" >/dev/null
	[ "$(fcfg profile presets_enabled)" = "1" ] && dial_presets "$port"
	at_run "$port" "AT+CGACT=1,${define}" >/dev/null
	sleep 3
}

# dial_stop <port>：断开拨号
dial_stop()
{
	local port="$1" define
	define=$(fcfg profile define_connect)
	at_run "$port" "AT+CGACT=0,${define}" >/dev/null
	ifdown "$(fcfg global v4_ifname)" "$(fcfg global v6_ifname)" 2>/dev/null
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
